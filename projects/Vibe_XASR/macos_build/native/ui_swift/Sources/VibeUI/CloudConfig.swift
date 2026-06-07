import Foundation

// 云端大模型 —— UI 侧数据(VibeUI)。与 app 端 CloudRefiner 的数据等价(解耦,各持一份)。

/// 云端配置 DTO,在 UI 与 app(SettingsStore/Keychain)间传递。
public struct CloudConfigDTO: Equatable, Sendable {
    public var enabled: Bool
    public var provider: String          // "openai" / "ark"
    public var baseURL: String
    public var model: String
    public var numbers, fillers, restate, hotwords: Bool   // 4 处理项
    public var apiKey: String
    public var templatesJSON: String     // [CloudTemplate] JSON
    public var activeTemplate: String    // "auto" | id
    public var autoOverride: String      // 空 = 跟随自动
    public var customProvidersJSON: String  // [CloudCustomProvider] JSON
    public var temperature: Double       // 采样温度 0~1(润色默认 0.3)
    public var maxTokens: Int            // 最大输出 token(默认 2048)
    public var logEnabled: Bool          // 是否记录「最近请求」(默认开)
    public var profilesJSON: String      // [CloudProfile] JSON(已存的命名配置,可一键切换)
    public var templateHotkeysJSON: String  // {templateId: TemplateHotkey} JSON(每模板绑定的快捷键)

    public init(enabled: Bool = false, provider: String = "openai",
                baseURL: String = "https://api.openai.com/v1", model: String = "gpt-4o-mini",
                numbers: Bool = true, fillers: Bool = true, restate: Bool = true, hotwords: Bool = true,
                apiKey: String = "", templatesJSON: String = "", activeTemplate: String = "auto",
                autoOverride: String = "", customProvidersJSON: String = "",
                temperature: Double = 0.3, maxTokens: Int = 2048, logEnabled: Bool = true,
                profilesJSON: String = "", templateHotkeysJSON: String = "") {
        self.enabled = enabled; self.provider = provider; self.baseURL = baseURL; self.model = model
        self.numbers = numbers; self.fillers = fillers; self.restate = restate; self.hotwords = hotwords
        self.apiKey = apiKey; self.templatesJSON = templatesJSON
        self.activeTemplate = activeTemplate; self.autoOverride = autoOverride
        self.customProvidersJSON = customProvidersJSON
        self.temperature = temperature; self.maxTokens = maxTokens; self.logEnabled = logEnabled
        self.profilesJSON = profilesJSON
        self.templateHotkeysJSON = templateHotkeysJSON
    }
    /// 4 处理项打包,给 buildAutoPromptUI。
    public var modsTuple: (Bool, Bool, Bool, Bool) { (numbers, fillers, restate, hotwords) }
}

/// 「最近请求」一条(排查 + 一键提 issue)。由 app 端 CloudRequestLog 映射而来。
public struct CloudReqLogEntry: Sendable, Identifiable {
    public let id: UUID
    public let at: Date
    public let provider: String   // 服务商 key
    public let baseURL: String
    public let model: String
    public let status: String     // "ok" | "timeout" | "error"
    public let ms: Int
    public let input: String      // 送入大模型的文本(规则处理后)
    public let output: String     // 大模型返回 / 错误信息
    public let prompt: String     // 实际发送的提示词
    public init(id: UUID, at: Date, provider: String, baseURL: String, model: String,
                status: String, ms: Int, input: String, output: String, prompt: String) {
        self.id = id; self.at = at; self.provider = provider; self.baseURL = baseURL; self.model = model
        self.status = status; self.ms = ms; self.input = input; self.output = output; self.prompt = prompt
    }
}

public struct CloudTestResult: Sendable {
    public var ok: Bool; public var ping: Int; public var add: String; public var msg: String
    public init(ok: Bool = false, ping: Int = 0, add: String = "", msg: String = "") {
        self.ok = ok; self.ping = ping; self.add = add; self.msg = msg
    }
}

public struct CloudTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: String; public var name: String; public var content: String
    public init(id: String, name: String, content: String) { self.id = id; self.name = name; self.content = content }
}

/// 单个模板绑定的快捷键(单键或修饰+键)。存在 sidecar map,不进 CloudTemplate(复制/分享不带本机快捷键)。
public struct TemplateHotkey: Codable, Equatable, Sendable {
    public var keyCode: Int
    public var mods: Int           // HotkeyMods.rawValue
    public var modifierOnly: Bool  // 纯修饰键(一般为 false:模板键要求非纯修饰)
    public init(keyCode: Int, mods: Int, modifierOnly: Bool) { self.keyCode = keyCode; self.mods = mods; self.modifierOnly = modifierOnly }
}
public enum CloudTemplateHotkeys {
    public static func decode(_ json: String) -> [String: TemplateHotkey] {
        guard let d = json.data(using: .utf8),
              let m = try? JSONDecoder().decode([String: TemplateHotkey].self, from: d) else { return [:] }
        return m
    }
    public static func encode(_ m: [String: TemplateHotkey]) -> String {
        (try? String(data: JSONEncoder().encode(m), encoding: .utf8) ?? "") ?? ""
    }
}

// 服务商(UI 显示用)
public struct CloudModelUI: Sendable, Equatable { public let id, label, note: String }
public struct CloudProviderUI: Sendable {
    public let key, label, mark, cls, desc, baseURL, keyHint, modelLabel, defaultModel: String
    public let models: [CloudModelUI]
    public let price: String
}
public enum CloudProvidersUI {
    /// 内置目录(23 家 OpenAI 兼容服务商,见 CloudCatalog.swift)。
    public static let all: [CloudProviderUI] = CloudCatalog.providers
    public static func find(_ k: String) -> CloudProviderUI { all.first { $0.key == k } ?? all[0] }
    public static func isBuiltin(_ k: String) -> Bool { all.contains { $0.key == k } }

    /// 本地化显示名:中文界面(简/繁)用中文译名(品牌名如 OpenAI / Claude / Groq 不译,保持原名);
    /// 其它语言(en/ja/ko)统一用英文目录名。这些多为中国大陆厂商,繁体界面亦沿用其中文名。
    @MainActor public static func localizedLabel(_ k: String) -> String {
        let r = L10n.shared.resolved
        if r == .zh || r == .zhHant, let zh = zhNames[k] { return zh }
        return find(k).label
    }
    private static let zhNames: [String: String] = [
        "qwen": "通义千问", "aliyun": "阿里云百炼", "doubao": "豆包 / 火山方舟",
        "moonshot": "月之暗面 Kimi", "kimicodingplan": "Kimi 编程套餐",
        "zhipuai": "智谱AI", "zhipuaicodingplan": "智谱AI 编程套餐",
        "minimaxtokenplan": "MiniMax Token 套餐", "qianfan": "百度千帆",
        "xiaomimimo": "小米 MiMo", "siliconcloud": "硅基流动",
    ]
}

/// 用户自定义服务商(任意 OpenAI 兼容接口)。只需名称 + BaseURL;具体模型在「模型」框自由填写。
public struct CloudCustomProvider: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var baseURL: String
    public init(id: String, label: String, baseURL: String) {
        self.id = id; self.label = label; self.baseURL = baseURL
    }
}

public enum CloudCustomProviders {
    public static func decode(_ json: String) -> [CloudCustomProvider] {
        guard let d = json.data(using: .utf8),
              let a = try? JSONDecoder().decode([CloudCustomProvider].self, from: d) else { return [] }
        return a
    }
    public static func encode(_ list: [CloudCustomProvider]) -> String {
        (try? String(data: JSONEncoder().encode(list), encoding: .utf8) ?? "") ?? ""
    }
}

/// 已保存的云端配置(命名快照),用于一键切换。含 API Key,故持久化到 Keychain(见 SettingsStore)。
public struct CloudProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var provider, baseURL, model, apiKey: String
    public var temperature: Double
    public var maxTokens: Int
    public var numbers, fillers, restate, hotwords: Bool
    public var activeTemplate, autoOverride: String
    public init(id: String, name: String, provider: String, baseURL: String, model: String, apiKey: String,
                temperature: Double, maxTokens: Int, numbers: Bool, fillers: Bool, restate: Bool, hotwords: Bool,
                activeTemplate: String, autoOverride: String) {
        self.id = id; self.name = name; self.provider = provider; self.baseURL = baseURL; self.model = model
        self.apiKey = apiKey; self.temperature = temperature; self.maxTokens = maxTokens
        self.numbers = numbers; self.fillers = fillers; self.restate = restate; self.hotwords = hotwords
        self.activeTemplate = activeTemplate; self.autoOverride = autoOverride
    }
}

public enum CloudProfiles {
    public static func decode(_ json: String) -> [CloudProfile] {
        guard let d = json.data(using: .utf8),
              let a = try? JSONDecoder().decode([CloudProfile].self, from: d) else { return [] }
        return a
    }
    public static func encode(_ list: [CloudProfile]) -> String {
        (try? String(data: JSONEncoder().encode(list), encoding: .utf8) ?? "") ?? ""
    }
    /// 把当前 DTO 快照成一个命名配置。
    public static func snapshot(_ c: CloudConfigDTO, id: String, name: String) -> CloudProfile {
        CloudProfile(id: id, name: name, provider: c.provider, baseURL: c.baseURL, model: c.model, apiKey: c.apiKey,
                     temperature: c.temperature, maxTokens: c.maxTokens,
                     numbers: c.numbers, fillers: c.fillers, restate: c.restate, hotwords: c.hotwords,
                     activeTemplate: c.activeTemplate, autoOverride: c.autoOverride)
    }
    /// 把一个配置套用到 DTO(只改与配置相关的字段,保留 enabled / 各种列表)。
    public static func apply(_ p: CloudProfile, to c: inout CloudConfigDTO) {
        c.provider = p.provider; c.baseURL = p.baseURL; c.model = p.model; c.apiKey = p.apiKey
        c.temperature = p.temperature; c.maxTokens = p.maxTokens
        c.numbers = p.numbers; c.fillers = p.fillers; c.restate = p.restate; c.hotwords = p.hotwords
        c.activeTemplate = p.activeTemplate; c.autoOverride = p.autoOverride
    }
}

/// 由 4 处理项实时拼成的「自动」prompt(UI 预览用,与 app buildAutoPrompt 等价)。
/// 随当前 UI 语言本地化(见 LocalizedPrompts)。
@MainActor public func buildAutoPromptUI(_ m: (Bool, Bool, Bool, Bool)) -> String {
    LocalizedPrompts.autoUI(m)
}

public enum CloudSeeds {
    /// 内置(锁定、不可改/删)的模板。第一套「自动」是 UI 特例(由开关实时拼成),不在此数组;
    /// 这里只保留「口语转书面」(id=t1)。其余为用户自建(id 形如 "tN-M")。
    public static let templates: [CloudTemplate] = [
        .init(id: "t1", name: "口语转书面", content: "把下面这段口述整理成通顺的书面表达，保留全部信息和原意，不要总结、不要遗漏。\n• 去掉口水词与重复，规整数字写法。\n• 专有名词以热词表为准：{{hotwords}}\n\n只输出整理后的文本。\n\n原文：{{transcript}}"),
    ]
    /// 新建模板的起始内容(带占位符,方便用户直接改)。
    public static let newTemplateStarter = "在此编写你的润色指令(例:把口述整理成简洁书面表达)。\n专有名词以热词表为准：{{hotwords}}\n\n只输出整理后的文本。\n\n原文：{{transcript}}"
    public static let tokens: [(token: String, desc: String)] = [
        ("{{transcript}}", "转写原文"), ("{{hotwords}}", "词典热词"),
        ("{{date}}", "当前日期"), ("{{changes}}", "本地规则改动"),
    ]
    public static func decode(_ json: String) -> [CloudTemplate] {
        guard let d = json.data(using: .utf8), let a = try? JSONDecoder().decode([CloudTemplate].self, from: d), !a.isEmpty else { return templates }
        // 迁移:移除已退役的内置种子(t2 会议纪要 / t3 本地纠错复核);确保锁定的 t1 始终存在。
        var out = a.filter { $0.id != "t2" && $0.id != "t3" }
        if !out.contains(where: { $0.id == "t1" }) { out.insert(templates[0], at: 0) }
        return out
    }
    public static func encode(_ t: [CloudTemplate]) -> String {
        (try? String(data: JSONEncoder().encode(t), encoding: .utf8) ?? "") ?? ""
    }
}
