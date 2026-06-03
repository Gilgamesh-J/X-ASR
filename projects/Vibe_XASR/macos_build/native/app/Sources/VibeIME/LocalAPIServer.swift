import Foundation
import Network
import VibeUI

// ============================================================
//  Vibe XASR — Local share API (共享)
//
//  A minimal embedded HTTP/1.1 server that lets the user's own coding agents
//  (Claude Code / Codex / OpenClaw / Hermes …) read their on-device dictation
//  data, so they can continue work from it. Design constraints:
//    • GET-only, READ-ONLY (never mutates user data over the wire).
//    • Bearer-key auth on EVERY request (random key, in SettingsStore).
//    • Bound to 127.0.0.1 by default; 0.0.0.0 only when the user explicitly
//      allows LAN. Nothing here ever reaches the internet.
//  The server is off by default and started from the 共享 settings tab.
// ============================================================

/// Thread-safety: all listener/connection callbacks run on `queue`; request
/// handling hops to the main actor to read the @MainActor stores. State mutated
/// only on `queue`. Marked @unchecked Sendable on that basis.
final class LocalAPIServer: @unchecked Sendable {
    static let shared = LocalAPIServer()

    private let queue = DispatchQueue(label: "com.xasr.vibexasr.api")
    private var listener: NWListener?
    private(set) var isRunning = false
    private(set) var boundPort: UInt16 = 0

    private var wantLAN = false

    /// (Re)start to match current settings (stops first). If the chosen port is in
    /// use (another dev server, etc.) it advances to the next ports and binds the
    /// first free one — `boundPort` reflects what actually bound.
    func restart(port: UInt16, allowLAN: Bool, enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel(); self.listener = nil
            self.isRunning = false; self.boundPort = 0
            guard enabled, port > 0 else { return }
            self.wantLAN = allowLAN
            self.bind(port, triesLeft: 12)
        }
    }

    /// Try to bind `port`; on failure advance to the next. Runs on `queue`.
    private func bind(_ port: UInt16, triesLeft: Int) {
        guard triesLeft > 0, let p = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if !wantLAN { params.requiredInterfaceType = .loopback }   // 127.0.0.1 / ::1 only
        guard let l = try? NWListener(using: params, on: p) else {
            bind(port &+ 1, triesLeft: triesLeft - 1); return
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.isRunning = true; self.boundPort = port
            case .failed:                 // port busy → try the next one
                self.isRunning = false
                if self.listener === l { self.listener = nil; l.cancel(); self.bind(port &+ 1, triesLeft: triesLeft - 1) }
                else { l.cancel() }
            case .cancelled:
                self.isRunning = false
            default: break
            }
        }
        self.listener = l
        l.start(queue: self.queue)
    }

    func stop() { restart(port: 0, allowLAN: false, enabled: false) }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// Read until the end of the HTTP header block (GET requests carry no body).
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = buf.subdata(in: buf.startIndex..<r.lowerBound)
                self.handle(conn, head: head)
                return
            }
            if isComplete || error != nil || buf.count > 256 * 1024 {
                self.send(conn, .text(400, "bad request")); return
            }
            self.receive(conn, buffer: buf)
        }
    }

    private func handle(_ conn: NWConnection, head: Data) {
        guard let req = APIRequest(head: head) else { send(conn, .text(400, "bad request")); return }
        Task { @MainActor in
            let resp = LocalAPIRouter.route(req)
            self.send(conn, resp)
        }
    }

    private func send(_ conn: NWConnection, _ resp: APIResponse) {
        conn.send(content: resp.httpData, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - Request / response

struct APIRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]

    init?(head: Data) {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        let raw = String(parts[1])
        if let q = raw.firstIndex(of: "?") {
            path = String(raw[..<q])
            query = APIRequest.parseQuery(String(raw[raw.index(after: q)...]))
        } else { path = raw; query = [:] }
        var h: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            h[line[..<c].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        headers = h
    }

    private static func parseQuery(_ s: String) -> [String: String] {
        var d: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            d[k] = v
        }
        return d
    }

    /// Bearer token from `Authorization: Bearer <key>` or `?key=`.
    var bearer: String? {
        if let a = headers["authorization"], a.lowercased().hasPrefix("bearer ") {
            return String(a.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return query["key"]
    }
    /// What base URL the client used (for the skill doc); falls back to loopback.
    var baseURL: String {
        if let host = headers["host"], !host.isEmpty { return "http://\(host)" }
        return "http://127.0.0.1:8473"
    }
}

struct APIResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(_ status: Int, _ obj: Any) -> APIResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return APIResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }
    static func text(_ status: Int, _ s: String, type: String = "text/plain; charset=utf-8") -> APIResponse {
        APIResponse(status: status, contentType: type, body: Data(s.utf8))
    }
    var httpData: Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var d = Data(head.utf8); d.append(body); return d
    }
}

// MARK: - Router (reads the @MainActor stores)

@MainActor
enum LocalAPIRouter {
    static func route(_ req: APIRequest) -> APIResponse {
        let s = SettingsStore.shared
        guard req.bearer == s.apiKey else {
            return .json(401, ["error": "unauthorized",
                               "hint": "pass ?key=<key> or header 'Authorization: Bearer <key>'"])
        }
        switch req.path {
        case "/", "/v1/ping":
            return .json(200, ["ok": true, "app": "Vibe XASR", "version": appVersion(),
                               "endpoints": ["/v1/history", "/v1/export", "/v1/config/hotwords",
                                             "/v1/config/replacements", "/v1/config/snippets", "/skill"]])
        case "/v1/history":
            return history(req)
        case "/v1/export":
            return export(req)
        case "/v1/config/hotwords":
            let words = s.hotwordsText.split(whereSeparator: \.isNewline).map(String.init)
            return .json(200, ["enabled": s.hotwordsEnabled, "score": s.hotwordsScore, "words": words])
        case "/v1/config/replacements":
            let rules = Replacements.parse(s.replacementsText).map { ["from": $0.from, "to": $0.to] }
            return .json(200, ["enabled": s.replacementsEnabled, "rules": rules])
        case "/v1/config/snippets":
            return .json(200, ["enabled": s.snippetsEnabled, "snippets": snippetList(s.snippetsJSON)])
        case "/skill", "/skill.md":
            return .text(200, SkillContent.markdown(baseURL: req.baseURL, key: s.apiKey),
                         type: "text/markdown; charset=utf-8")
        default:
            return .json(404, ["error": "not found", "path": req.path])
        }
    }

    // ----- endpoints -----

    private static func history(_ req: APIRequest) -> APIResponse {
        let items = filtered(req)
        let iso = ISO8601DateFormatter()
        return .json(200, ["count": items.count, "items": items.map { entryJSON($0, iso) }])
    }

    private static func export(_ req: APIRequest) -> APIResponse {
        let asc = filtered(req).sorted { $0.date < $1.date }
        if (req.query["format"] ?? "md") == "txt" {
            let body = asc.map { "\(timeStr($0.date))  \($0.text)" }.joined(separator: "\n")
            return .text(200, body.isEmpty ? "(无记录)" : body)
        }
        var md = "# Vibe XASR 记录导出\n\n"
        var lastDay = ""
        for e in asc {
            let day = dayLabel(e.date)
            if day != lastDay { md += "\n## \(day)\n\n"; lastDay = day }
            if let t = e.title, !t.isEmpty { md += "**\(t)**\n" }
            md += "- \(timeStr(e.date))　\(e.text)\n"
        }
        if asc.isEmpty { md += "_(该范围内没有记录)_\n" }
        return .text(200, md, type: "text/markdown; charset=utf-8")
    }

    // ----- helpers -----

    /// Apply ?date / ?from&to / ?limit filters to the (newest-first) history.
    private static func filtered(_ req: APIRequest) -> [HistoryItem] {
        var items = HistoryStore.shared.historyItems
        if let ds = req.query["date"], let (start, end) = dayRange(ds) {
            items = items.filter { $0.date >= start && $0.date < end }
        } else if let f = req.query["from"], let t = req.query["to"],
                  let (fs, _) = dayRange(f), let (_, te) = dayRange(t) {
            items = items.filter { $0.date >= fs && $0.date < te }
        }
        if let lim = req.query["limit"], let n = Int(lim), n > 0 { items = Array(items.prefix(n)) }
        return items
    }

    private static func entryJSON(_ e: HistoryItem, _ iso: ISO8601DateFormatter) -> [String: Any] {
        var d: [String: Any] = ["text": e.text, "date": iso.string(from: e.date), "mode": e.mode]
        if let t = e.title, !t.isEmpty { d["title"] = t }
        if !e.tags.isEmpty { d["tags"] = e.tags }
        return d
    }

    private static func snippetList(_ json: String) -> [[String: String]] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return arr.compactMap { o in
            guard let t = o["t"], let x = o["x"] else { return nil }
            return ["trigger": t, "text": x]
        }
    }

    /// "today" / "yesterday" / "yyyy-MM-dd" → [startOfDay, nextDay).
    private static func dayRange(_ s: String) -> (Date, Date)? {
        let cal = Calendar.current
        var day: Date?
        switch s.lowercased() {
        case "today": day = Date()
        case "yesterday": day = cal.date(byAdding: .day, value: -1, to: Date())
        default:
            let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
            day = f.date(from: s)
        }
        guard let d = day else { return nil }
        let start = cal.startOfDay(for: d)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }

    private static func timeStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    private static func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日 EEEE"
        return f.string(from: d)
    }
    private static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.3.0"
    }
}

// MARK: - Skill document (served at /skill, pasted into the agent's skills dir)

enum SkillContent {
    static func markdown(baseURL: String, key: String) -> String {
        """
        # Vibe XASR — 本地语音记录 / 词典接入

        通过 Vibe XASR 在本机暴露的只读 HTTP API,读取用户的**语音听写记录**、**词典(热词/替换)**、**口令**,
        以便在当前编程助手里接续工作(例如把今天口述的需求导出后继续实现)。

        - Base URL: `\(baseURL)`
        - 鉴权:每个请求都要带 key(二选一):
          - 头部 `Authorization: Bearer \(key)`
          - 或查询参数 `?key=\(key)`
        - 全部为 **GET / 只读**;数据仅在本机,默认只监听 127.0.0.1。

        ## 何时使用
        当用户说「接着我刚才/今天口述的内容做」「按我的词典/口令」之类时,先调对应接口取数据再动手。

        ## 接口
        | 用途 | 请求 |
        |---|---|
        | 健康检查 | `GET /v1/ping` |
        | 全部记录(最新在前) | `GET /v1/history` |
        | 指定某天 | `GET /v1/history?date=today`(或 `yesterday` / `2026-06-03`) |
        | 日期区间 | `GET /v1/history?from=2026-06-01&to=2026-06-03` |
        | 导出成稿(Markdown) | `GET /v1/export?date=today&format=md` |
        | 导出成稿(纯文本) | `GET /v1/export?date=today&format=txt` |
        | 词典·热词 | `GET /v1/config/hotwords` |
        | 词典·替换 | `GET /v1/config/replacements` |
        | 口令 | `GET /v1/config/snippets` |

        ## 示例
        ```bash
        # 今天的口述,导成 Markdown 接着干
        curl -s -H "Authorization: Bearer \(key)" "\(baseURL)/v1/export?date=today&format=md"

        # 读用户的热词词典
        curl -s "\(baseURL)/v1/config/hotwords?key=\(key)"
        ```

        ## 说明
        - 401 = key 不对或缺失。
        - 若连接被拒:请确认用户在 Vibe XASR「共享」里开启了服务;局域网访问需用户单独允许。
        """
    }
}
