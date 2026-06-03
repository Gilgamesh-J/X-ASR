import Foundation
import VibeUI

/// Downloads a streaming latency tier (chunk-<tier>ms) on demand, with live
/// progress, into Application Support/VibeXASR/models/chunk-<tier>ms/.
///
/// Files (per tier, ~615 MB total): encoder-<tier>ms.onnx, decoder-<tier>ms.onnx,
/// joiner-<tier>ms.onnx, tokens.txt — at repo path
/// deployment/models/chunk-<tier>ms-model/<file>.
///
/// Two download SOURCES are supported, user-selectable in Settings:
///   * ModelScope (DEFAULT, faster esp. in CN):
///       https://www.modelscope.ai/models/Gilgamesh-J/X-ASR-zh-en/resolve/master/<path>
///   * HuggingFace (alternative):
///       https://huggingface.co/GilgameshWind/X-ASR-zh-en/resolve/main/<path>
///
/// Both mirrors host the identical file tree, so only the host / repo owner /
/// default branch differ (verified 2026-06-01: the ModelScope `.ai` international
/// mirror serves every tier file with matching byte sizes). The chosen source is
/// persisted in UserDefaults under `modelDownloadSource` and defaults to ModelScope.
///
/// Each file is downloaded to a temp location, then moved into the tier dir; the
/// whole tier dir is only considered "ready" once all four files are present, so
/// a partial download never satisfies `ModelPaths.tierAvailable`.
@MainActor
final class ModelDownloader: NSObject, ObservableObject, ModelManagerBridge, ModelDownloadSourcing {

    static let shared = ModelDownloader()

    /// HuggingFace coordinates.
    private let hfRepo = "GilgameshWind/X-ASR-zh-en"          // HF repo id (owner casing)
    private let hfHost = "https://huggingface.co"
    /// ModelScope coordinates (international `.ai` mirror; same file tree).
    private let msRepo = "Gilgamesh-J/X-ASR-zh-en"            // MS repo id (different owner casing)
    private let msHost = "https://www.modelscope.ai"

    /// UserDefaults key persisting the chosen download source.
    private static let sourceKey = "modelDownloadSource"

    /// Per-tier download state surfaced to the UI.
    @Published private(set) var progress: [Int: Double] = [:]   // tier → 0...1
    @Published private(set) var active: Set<Int> = []           // tiers downloading
    @Published private(set) var failed: Set<Int> = []           // tiers that errored

    /// Chosen download source (ModelScope default). Persisted to UserDefaults on
    /// change so the Settings picker survives relaunch. Satisfies `ModelDownloadSourcing`.
    @Published var source: ModelDownloadSource {
        didSet {
            guard source != oldValue else { return }
            UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
            log("download source → \(source.label)")
        }
    }

    /// Bumped whenever an install completes/changes so SwiftUI re-queries
    /// `ModelPaths.tierAvailable` (which reads the filesystem).
    @Published private(set) var installsVersion = 0

    private var tasks: [Int: URLSessionDownloadTask] = [:]
    /// Maps a task → (tier, fileName, remaining files to fetch) for sequencing.
    private final class Job {
        let tier: LatencyTier
        var remaining: [String]
        let destDir: URL
        init(tier: LatencyTier, files: [String], destDir: URL) {
            self.tier = tier; self.remaining = files; self.destDir = destDir
        }
    }
    private var jobs: [Int: Job] = [:]

    override init() {
        // Restore the persisted source; default to ModelScope when unset/invalid.
        let raw = UserDefaults.standard.string(forKey: Self.sourceKey)
        self.source = raw.flatMap(ModelDownloadSource.init(rawValue:)) ?? .modelScope
        super.init()
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 3600   // big files
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private func files(for tier: LatencyTier) -> [String] {
        ["encoder-\(tier.token)ms.onnx",
         "decoder-\(tier.token)ms.onnx",
         "joiner-\(tier.token)ms.onnx",
         "tokens.txt"]
    }

    /// Repo-relative path of a tier file, shared by both hosts.
    private func relPath(tier: LatencyTier, file: String) -> String {
        "deployment/models/chunk-\(tier.token)ms-model/\(file)"
    }

    /// Resolve URL for the currently selected source. Both mirrors expose the same
    /// file tree, so only host / repo owner / default branch differ.
    private func resolveURL(tier: LatencyTier, file: String) -> URL {
        let path = relPath(tier: tier, file: file)
        switch source {
        case .modelScope:
            return URL(string: "\(msHost)/models/\(msRepo)/resolve/master/\(path)")!
        case .huggingFace:
            return URL(string: "\(hfHost)/\(hfRepo)/resolve/main/\(path)")!
        }
    }

    // MARK: ModelManagerBridge

    func isTierDownloaded(_ tier: LatencyTier) -> Bool {
        _ = installsVersion           // re-read after each install
        return ModelPaths.tierAvailable(tier)
    }
    func isTierBundled(_ tier: LatencyTier) -> Bool { tier.isBundled }
    func downloadProgress(_ tier: LatencyTier) -> Double? {
        active.contains(tier.rawValue) ? (progress[tier.rawValue] ?? 0) : nil
    }
    func didTierFail(_ tier: LatencyTier) -> Bool { failed.contains(tier.rawValue) }

    /// Begin (or resume) downloading a tier. No-op if bundled / already present.
    func startDownload(_ tier: LatencyTier) {
        guard !tier.isBundled, !ModelPaths.tierAvailable(tier),
              !active.contains(tier.rawValue) else { return }
        failed.remove(tier.rawValue)
        let dir = ModelPaths.downloadedTierDir(tier.token)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Only fetch files that are not already present (resume across launches).
        let needed = files(for: tier).filter {
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        guard !needed.isEmpty else { installsVersion += 1; return }

        active.insert(tier.rawValue)
        progress[tier.rawValue] = 0
        let job = Job(tier: tier, files: needed, destDir: dir)
        jobs[tier.rawValue] = job
        log("start tier=\(tier.token)ms via \(source.label) — \(needed.count) file(s)")
        fetchNext(job)
    }

    /// Cancel an in-flight tier download.
    func cancelDownload(_ tier: LatencyTier) {
        tasks[tier.rawValue]?.cancel()
        tasks[tier.rawValue] = nil
        jobs[tier.rawValue] = nil
        active.remove(tier.rawValue)
        progress[tier.rawValue] = nil
    }

    /// Delete a downloaded tier's files (frees ~615 MB). No-op for the bundled
    /// tier (it lives in the read-only bundle).
    @discardableResult
    func deleteTier(_ tier: LatencyTier) -> Bool {
        guard !tier.isBundled else { return false }
        cancelDownload(tier)
        let dir = ModelPaths.downloadedTierDir(tier.token)
        // Remove the whole tier dir; if that fails (e.g. partial perms), fall back
        // to deleting each known file so state still flips to "not downloaded".
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            for f in files(for: tier) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        failed.remove(tier.rawValue)
        progress[tier.rawValue] = nil
        installsVersion += 1
        log("deleted tier=\(tier.token)ms (downloaded=\(ModelPaths.tierAvailable(tier)))")
        return !ModelPaths.tierAvailable(tier)
    }

    // MARK: sequencing

    private func fetchNext(_ job: Job) {
        guard let file = job.remaining.first else {
            // All files done.
            active.remove(job.tier.rawValue)
            progress[job.tier.rawValue] = 1
            jobs[job.tier.rawValue] = nil
            installsVersion += 1
            log("tier=\(job.tier.token)ms complete")
            return
        }
        start(file: file, for: job, url: resolveURL(tier: job.tier, file: file))
    }

    /// Kick off the current file's download task.
    private func start(file: String, for job: Job, url: URL) {
        let task = session.downloadTask(with: url)
        task.taskDescription = "\(job.tier.rawValue)|\(file)"
        tasks[job.tier.rawValue] = task
        task.resume()
    }

    private func handleFinished(tier: Int, file: String, tempURL: URL) {
        guard let job = jobs[tier] else { return }
        let dest = job.destDir.appendingPathComponent(file)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            fail(tier: tier)
            return
        }
        job.remaining.removeAll { $0 == file }
        fetchNext(job)
    }

    private func fail(tier: Int) {
        active.remove(tier)
        progress[tier] = nil
        jobs[tier] = nil
        tasks[tier] = nil
        failed.insert(tier)
        log("tier=\(tier) FAILED")
    }

    private func log(_ msg: String) {
        FileHandle.standardError.write("[ModelDownloader] \(msg)\n".data(using: .utf8)!)
    }
}

// MARK: - URLSessionDownloadDelegate (nonisolated; hops to main)

extension ModelDownloader: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let desc = downloadTask.taskDescription,
              let tierStr = desc.split(separator: "|").first,
              let tier = Int(tierStr),
              let t = LatencyTier(rawValue: tier),
              totalBytesExpectedToWrite > 0 else { return }
        // Approximate whole-tier progress: completed files + the current one's
        // fraction, averaged over the 4 files of a tier.
        let perFile = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak self] in
            guard let self, let job = self.jobs[tier] else { return }
            let all = self.files(for: t).count
            let doneFiles = all - job.remaining.count
            self.progress[tier] = (Double(doneFiles) + perFile) / Double(all)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let desc = downloadTask.taskDescription else { return }
        let parts = desc.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let tier = Int(parts[0]) else { return }
        let file = parts[1]
        let http = downloadTask.response as? HTTPURLResponse
        let ok = (http?.statusCode ?? 200) < 400
        // Move the temp file synchronously here (it's deleted when this returns).
        // Copy to a stable temp path, then hand off to the main actor.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        if ok { try? FileManager.default.moveItem(at: location, to: staged) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if ok {
                self.handleFinished(tier: tier, file: file, tempURL: staged)
            } else {
                try? FileManager.default.removeItem(at: staged)
                self.fail(tier: tier)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error, let desc = task.taskDescription,
              let tierStr = desc.split(separator: "|").first,
              let tier = Int(tierStr) else { return }
        // Ignore explicit cancels (we already cleared state).
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor [weak self] in
            self?.fail(tier: tier)
        }
    }
}
