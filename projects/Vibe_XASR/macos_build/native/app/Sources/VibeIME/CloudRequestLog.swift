import Foundation

/// 云端润色「最近请求」记录,便于用户排查 + 一键提 issue。
/// 线程安全:CloudRefiner 在后台线程写,设置页 UI 在主线程读。环形缓冲,保留最近 100 条。
final class CloudRequestLog: @unchecked Sendable {
    static let shared = CloudRequestLog()

    struct Entry: Sendable {
        let id = UUID()
        let at: Date
        let provider: String   // 服务商 key(如 openai / aliyun / custN)
        let baseURL: String
        let model: String
        let status: String     // "ok" | "timeout" | "error"
        let ms: Int
        let input: String      // 送入大模型的文本(规则处理后)
        let output: String     // 大模型返回(失败时=错误信息)
        let prompt: String     // 实际发送的提示词(占位符已替换)
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var _enabled = true
    private var _pendingOriginal = ""
    private let cap = 20

    /// 下一条记录用的「原始 ASR」(X-ASR 引擎原始输出,不含同音字/替换/顺滑等任何规则)。
    /// AppDelegate 在每次润色前设置;CloudRefiner 记录时取它当 input。
    var pendingOriginal: String {
        get { lock.lock(); defer { lock.unlock() }; return _pendingOriginal }
        set { lock.lock(); defer { lock.unlock() }; _pendingOriginal = newValue }
    }
    private static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

    /// 是否记录(用户可在设置里关)。线程安全。
    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); defer { lock.unlock() }; _enabled = newValue }
    }

    func record(provider: String, baseURL: String, model: String, status: String, ms: Int,
                input: String, output: String, prompt: String) {
        let e = Entry(at: Date(), provider: provider, baseURL: baseURL, model: model, status: status, ms: ms,
                      input: Self.clip(input, 4000), output: Self.clip(output, 4000), prompt: Self.clip(prompt, 6000))
        lock.lock(); defer { lock.unlock() }
        guard _enabled else { return }
        entries.insert(e, at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
    }
    func snapshot() -> [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
    func clear() { lock.lock(); defer { lock.unlock() }; entries.removeAll() }
}
