import Foundation

// 云端大模型润色 —— 后端 + 数据 + prompt 拼接。
// =========================================================================
// 调 OpenAI / 火山方舟(Ark)兼容的 chat/completions 接口。设计来源:云端llm「大模型设置」。

// MARK: - 服务商数据

struct LLMModel: Sendable, Equatable { let id: String; let label: String; let note: String }

struct LLMProvider: Sendable {
    let key: String          // "openai" / "ark"
    let label: String        // 显示名
    let mark: String         // logo 里的字
    let cls: String          // CSS 风格类(UI 用):"oa" / "ark"
    let desc: String
    let baseURL: String
    let keyHint: String
    let modelLabel: String   // "模型" / "模型 / 接入点"
    let models: [LLMModel]
    let price: String
}

enum LLMProviders {
    static let openai = LLMProvider(
        key: "openai", label: "OpenAI", mark: "AI", cls: "oa",
        desc: "OpenAI 官方或兼容接口",
        baseURL: "https://api.openai.com/v1",
        keyHint: "sk-xxxxxxxxxxxxxxxx",
        modelLabel: "模型",
        models: [
            LLMModel(id: "gpt-4o-mini", label: "gpt-4o-mini", note: "快·便宜"),
            LLMModel(id: "gpt-4o",      label: "gpt-4o",      note: "均衡"),
            LLMModel(id: "gpt-4.1-mini",label: "gpt-4.1-mini",note: "快"),
            LLMModel(id: "gpt-4.1",     label: "gpt-4.1",     note: "质量高"),
        ],
        price: "按 token 计费 · gpt-4o-mini ≈ ¥0.001 / 千 token")

    static let ark = LLMProvider(
        key: "ark", label: "火山方舟 (Ark)", mark: "方", cls: "ark",
        desc: "火山引擎·豆包大模型",
        baseURL: "https://ark.cn-beijing.volces.com/api/v3",
        keyHint: "方舟 API Key",
        modelLabel: "模型 / 接入点",
        models: [
            LLMModel(id: "doubao-lite-32k", label: "doubao-lite-32k", note: "快·便宜"),
            LLMModel(id: "doubao-pro-4k",   label: "doubao-pro-4k",   note: "均衡"),
            LLMModel(id: "doubao-pro-32k",  label: "doubao-pro-32k",  note: "长文"),
        ],
        price: "按 token 计费 · doubao-pro ≈ ¥0.0008 / 千 token")

    static let all: [LLMProvider] = [openai, ark]
    static func find(_ key: String) -> LLMProvider { all.first { $0.key == key } ?? openai }
}

// MARK: - 处理项 → 自动 prompt

struct RefineMods: Sendable, Equatable {
    var numbers = true, fillers = true, restate = true, hotwords = true
}

/// 由处理项开关实时拼成的「自动」prompt(设计 buildPrompt 的 Swift 版)。
/// {{hotwords}} / {{transcript}} 占位符保留,调用时替换。
func buildAutoPrompt(_ m: RefineMods) -> String {
    var r: [String] = []
    if m.numbers { r.append("• 数字规整：把口语数字转成阿拉伯数字（一百二十三 → 123、三点半 → 3:30、百分之二十 → 20%）；成语、计数词保持不变。") }
    if m.fillers { r.append("• 去口水词：删掉「嗯 / 呃 / 唉」等语气词和口吃式重复（那个那个 → 那个、我我我 → 我）；正常叠词（看看 / 想想）保留。") }
    if m.restate { r.append("• 改口纠正：说话人中途自我更正（常见「不对 / 不是 / 应该是 / 我还是…吧」等）时，必须删掉被否定、被替换掉的前半句，只保留最终说法；必要时把最终说法补成通顺完整的句子。例：「我想开发现代风格的客户端，不对，还是古早风格的吧」→「我想开发古早风格的客户端」。") }
    if m.hotwords { r.append("• 热词修正：优先按热词表修正同音 / 近音误写，正确写法以热词表为准。\n  热词表：{{hotwords}}") }
    let body = r.isEmpty ? "•（暂未选择任何处理项，将原样返回文本）" : r.joined(separator: "\n")
    return "你是语音转写(ASR)的后处理助手。任务：把这段口述整理成说话人最终想表达的样子。只做下面已开启规则要求的增删，其余内容保持原样——不要改写用词、不要臆造或补充信息、不要总结、不要翻译。\n\n\(body)\n\n【本地规则已做的改动 · 可能有误，请核对】\n下面是本机规则(同音字纠正 / 替换规则)对原始识别文本所做的修改；本地规则可能弄错，若发现改错了请改回正确写法，没问题则保持：\n{{changes}}\n\n只输出整理后的纯文本，不要解释、不要加引号。\n\n原文：{{transcript}}"
}

/// 占位符替换:{{hotwords}} / {{date}} 在拼 system 时替换;{{transcript}} 留给后端(refine 时才有转写)。
enum PromptFill {
    static func staticTokens(_ tpl: String, hotwords: String, date: String, changes: String = "(无)") -> String {
        tpl.replacingOccurrences(of: "{{hotwords}}", with: hotwords.isEmpty ? "(无)" : hotwords)
           .replacingOccurrences(of: "{{date}}", with: date)
           .replacingOccurrences(of: "{{changes}}", with: changes.isEmpty ? "(无)" : changes)
    }
}

/// 内置模板种子(设计 SEED_TPLS) + 占位符清单(设计 TOKENS),供 UI 初始化。
struct PromptTemplate: Sendable, Equatable, Codable { var id: String; var name: String; var content: String }
enum PromptSeeds {
    static let templates: [PromptTemplate] = [
        .init(id: "t1", name: "口语转书面", content: "把下面这段口述整理成通顺的书面表达，保留全部信息和原意，不要总结、不要遗漏。\n• 去掉口水词与重复，规整数字写法。\n• 专有名词以热词表为准：{{hotwords}}\n\n只输出整理后的文本。\n\n原文：{{transcript}}"),
        .init(id: "t2", name: "会议纪要", content: "把下面的会议口述整理成结构化纪要：\n1）一句话主题；\n2）关键结论（要点列表）；\n3）待办事项（负责人 + 事项）。\n专有名词以热词表为准：{{hotwords}}\n\n会议转写：{{transcript}}"),
        .init(id: "t3", name: "本地纠错复核", content: "你是语音转写后处理助手。下面给出原始识别文本，以及本机规则（同音字纠正 / 替换规则）已做的改动。请在保持原意、不增删信息的前提下整理文本，并重点核对本地规则的改动——若改错了请改回正确写法，没问题则保持。\n\n本地规则改动（可能有误）：\n{{changes}}\n\n专有名词以热词表为准：{{hotwords}}\n\n只输出整理后的纯文本，不要解释、不要加引号。\n\n原文：{{transcript}}"),
    ]
    static let tokens: [(token: String, desc: String)] = [
        ("{{transcript}}", "转写原文"), ("{{hotwords}}", "词典热词"),
        ("{{date}}", "当前日期"), ("{{changes}}", "本地规则改动"),
    ]
}

// MARK: - CloudRefiner 后端

/// 云端后端:调 OpenAI/Ark 兼容 chat/completions。无可变共享状态(全 let),线程安全。
final class CloudRefiner: RefinerBackend, @unchecked Sendable {
    let baseURL: String
    let model: String
    let apiKey: String
    let temperature: Double
    let maxTokens: Int
    let provider: String

    init(baseURL: String, model: String, apiKey: String, temperature: Double = 0.3, maxTokens: Int = 2048,
         provider: String = "") {
        self.baseURL = CloudRefiner.trimURL(baseURL)
        self.model = model
        self.apiKey = apiKey
        self.temperature = temperature
        self.maxTokens = maxTokens > 0 ? maxTokens : 2048
        self.provider = provider
    }

    var isReady: Bool { !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty }

    /// system 为拼好的指令(可含 {{transcript}});text 为转写。替换后作为单条 user 消息发送。
    func refine(system: String, text: String) async -> String? {
        let prompt = system.contains("{{transcript}}")
            ? system.replacingOccurrences(of: "{{transcript}}", with: text)
            : "\(system)\n\n原文：\(text)"
        // 日志 input 用「原始 ASR」(引擎原始输出,不含任何规则);AppDelegate 在润色前已设好。
        let original = CloudRequestLog.shared.pendingOriginal
        let logInput = original.isEmpty ? text : original
        // 内容超过 Max Tokens(输出上限)→ 不调用模型(否则会被截断),记一条并回退规则版。
        let estIn = CloudRefiner.estimateTokens(text)
        if estIn > maxTokens {
            CloudRequestLog.shared.record(provider: provider, baseURL: baseURL, model: model,
                status: "skipped", ms: 0, input: logInput,
                output: "内容约 \(estIn) token,超过 Max Tokens(\(maxTokens))。未调用模型,已回退规则版插入。请调大 Max Tokens,或缩短单次说话内容。",
                prompt: prompt)
            return nil
        }
        let t0 = Date()
        do {
            let data = try await CloudRefiner.chat(
                baseURL: baseURL, model: model, apiKey: apiKey,
                messages: [["role": "user", "content": prompt]],
                maxTokens: maxTokens, temperature: temperature)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let out = CloudRefiner.extractContent(data)
            CloudRequestLog.shared.record(provider: provider, baseURL: baseURL, model: model,
                                          status: out == nil ? "error" : "ok", ms: ms,
                                          input: logInput, output: out ?? "返回内容为空(无 choices/content)", prompt: prompt)
            return out
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let cancelled = (error is CancellationError) || (error as NSError).code == NSURLErrorCancelled
            CloudRequestLog.shared.record(provider: provider, baseURL: baseURL, model: model,
                                          status: cancelled ? "timeout" : "error", ms: ms,
                                          input: logInput, output: cancelled ? "超时取消(>润色超时)" : error.localizedDescription,
                                          prompt: prompt)
            return nil
        }
    }

    // MARK: 共用 HTTP

    private static func trimURL(_ s: String) -> String {
        var u = s.trimmingCharacters(in: .whitespaces)
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    /// 粗估 token 数:CJK ≈ 1 token/字,ASCII ≈ 0.3,其它 ≈ 0.7。用于「内容超 Max Tokens」预检。
    static func estimateTokens(_ s: String) -> Int {
        var t = 0.0
        for u in s.unicodeScalars {
            if (0x4E00...0x9FFF).contains(u.value) || (0x3040...0x30FF).contains(u.value) { t += 1.0 }
            else if u.value < 128 { t += 0.3 }
            else { t += 0.7 }
        }
        return Int(t.rounded(.up))
    }

    static func chat(baseURL: String, model: String, apiKey: String,
                     messages: [[String: String]], maxTokens: Int, temperature: Double = 0) async throws -> Data {
        guard let url = URL(string: "\(trimURL(baseURL))/chat/completions") else {
            throw NSError(domain: "cloud", code: -1, userInfo: [NSLocalizedDescriptionKey: "Base URL 无效"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "temperature": temperature, "messages": messages, "max_tokens": maxTokens,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "cloud", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: extractError(data) ?? "HTTP \(http.statusCode)"])
        }
        return data
    }

    static func extractContent(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = json["error"] as? [String: Any], let m = err["message"] as? String { return m }
        if let m = json["message"] as? String { return m }
        return nil
    }

    /// 测试连接 + 真实往返延迟。返回 (ok, 往返ms, 润色预计增加延迟, 失败原因)。
    static func testConnection(baseURL: String, model: String, apiKey: String) async
        -> (ok: Bool, ping: Int, add: String, msg: String) {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            return (false, 0, "", "缺少 API Key")
        }
        let t0 = Date()
        do {
            _ = try await chat(baseURL: baseURL, model: model, apiKey: apiKey,
                               messages: [["role": "user", "content": "hi"]], maxTokens: 1)
            let ping = Int(Date().timeIntervalSince(t0) * 1000)
            // 整段润色总耗时 ≈ 本次往返(网络 + 首字/思考)+ 生成几十~上百字输出(经验 +1~3s)。
            // 故总耗时 = 往返 + 生成,必然 ≥ 单次往返(修正:旧版写死 +0.3s,与实测往返自相矛盾)。
            let rtt = Double(ping) / 1000.0
            let add = String(format: "%.1f–%.1fs", rtt + 1.0, rtt + 3.0)
            return (true, ping, add, "")
        } catch {
            return (false, 0, "", error.localizedDescription)
        }
    }
}
