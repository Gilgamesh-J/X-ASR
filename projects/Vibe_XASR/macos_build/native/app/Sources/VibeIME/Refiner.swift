import Foundation

// AI 润色(Beta)—— 后端无关的骨架。
// =========================================================================
// 设计:
//   · 后端(llama.cpp / MLX / 子进程)实现 `RefinerBackend`,只管"文本进 → 润色出"。
//   · `Refiner` 门面协调"后端推理 + 护栏 + 回退",保证任何异常/超时/护栏不过都安全
//     回退到传入的规则版文本 —— 绝不丢字、绝不卡住插入。
//   · 挂接点见 AppDelegate.corrected():Defiller 之后、ChineseITN 之前(isFinal 时)。
//   · 推理是 async:绝不能同步阻塞主线程/插入路径。
//
// 评估定稿(projects/Vibe_XASR/refiner_eval/):只做「去口癖 + 改口」,不做分段
// (0.6B 分段做不好);它是「润色」不是「忠实转写」,会改写口语,故默认关 + Beta 角标。
//
// 注:本文件并发隔离(Swift 6 strict concurrency)需本地 `swift build` 核对微调;
//     纯逻辑的 `Guardrails` 不涉并发,可独立编译测试。

/// 润色后端协议。实现负责加载模型 + 单次整段推理。
/// Sendable:推理在后台线程,实现需自行保证线程安全(actor,或 final class + 锁 / @unchecked Sendable)。
protocol RefinerBackend: AnyObject, Sendable {
    /// 模型是否已加载就绪。未就绪时门面直接回退原文(不等待)。
    var isReady: Bool { get }
    /// 对整段文本润色一次;返回 nil 表示后端无法处理(回退原文)。
    /// 入参 system 为定稿指令,text 为待润色文本。
    func refine(system: String, text: String) async -> String?
    /// 后端是否会在正文后追加「不确定词列表」(CPM5 本地模型的自报机制)。
    /// 门面据此决定是否剥离该列表;云端模型不会,用默认 false。
    var emitsUncertainList: Bool { get }
}

extension RefinerBackend {
    var emitsUncertainList: Bool { false }
}

/// AI 润色(Beta)门面。线程模型:门面在 MainActor,真正推理在后端的后台线程。
@MainActor
final class Refiner {
    static let shared = Refiner()

    /// 当前后端(默认 llama.cpp;懒加载)。nil = 未配置/模型未下载 → polish 为安全 no-op。
    var backend: RefinerBackend?

    /// 推理超时(秒)。超时即回退规则版。
    var timeout: TimeInterval = 4.0

    /// 指令构建器。本地=固定 systemPrompt;云端=AppDelegate 按配置(处理项/模板/热词,已替换
    /// {{hotwords}}/{{date}})拼成、可含 {{transcript}} 占位符,由后端在 refine 时替换为转写。
    var systemProvider: @MainActor () -> String = { Refiner.systemPrompt }

    /// CPM5(MiniCPM5-1B)官方固定 system prompt —— 开发者 corrector.py 原文,模型 SFT 即按此训练。
    /// 输出格式 `corrected_text<KEY>[词1、词2]`(<KEY> 后为不确定词,见 stripUncertainList)。
    /// ⚠️ 必须原样发送:不带它,模型走分布外退化路径(分隔符变 `<font>`/`<center>` 残渣、质量下降)。
    static let systemPrompt =
        "你是流式ASR后处理助手。输入ASR原始识别文本，输出修正后的规范文本。"
        + "去口癖、纠错字、加标点，规范书写格式，"
        + "保留全部语义不捏造。不确定的词在末尾标注<KEY>[词1、词2]。"
        + "直接输出结果，不要解释。"

    /// 入口:对最终文本润色。失败/超时/护栏不过 → 返回原文(安全回退)。
    /// - Parameter text: 已过规则链(Defiller 之后、ITN 之前)的整段文本。
    func polish(_ text: String) async -> String {
        guard let backend, backend.isReady, Refiner.shouldRun(text) else { return text }
        let sys = systemProvider()
        let raw = await Refiner.race(timeout: timeout) { await backend.refine(system: sys, text: text) }
        guard let raw, !raw.isEmpty else { return text }                 // 超时/空 → 回退
        var out = Refiner.stripWrapping(raw)
        if backend.emitsUncertainList { out = Refiner.stripUncertainList(out) }  // CPM5:剥掉尾部不确定词列表,绝不进插入路径
        out = Refiner.collapseExactDoubleEcho(out, relativeTo: text)     // 短句偶发「整段重复两遍」→ 折回一遍
        guard !out.isEmpty, Guardrails.accept(src: text, out: out) else { return text }  // 护栏不过 → 回退
        return out
    }

    /// 触发判断:太短就别跑(省延迟、降风险)。够长才送后端。
    static func shouldRun(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6
    }

    /// 清洗模型输出:剥掉偶发的包裹引号与残留 <think>…</think>。
    static func stripWrapping(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "<think>"), let e = t.range(of: "</think>"), r.lowerBound < e.upperBound {
            t.removeSubrange(r.lowerBound..<e.upperBound)
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let quotes: Set<Character> = ["\"", "“", "”", "「", "」", "'"]
        if let f = t.first, quotes.contains(f) { t.removeFirst() }
        if let l = t.last, quotes.contains(l) { t.removeLast() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 剥离模型在正文后追加的「不确定词列表」,只保留正文(列表本期丢弃,未来做兜底再用)。
    /// 官方格式(带固定 system prompt)为 `corrected_text<KEY>[词1、词2]` —— 按分隔符 `<KEY>` 切。
    /// 兜底:个别量化输出可能无 `<KEY>` 而残留尾部 `<…>` 块(分布外退化),再按尾部 `<…` 块剥一道;
    /// 语音正文几乎不含 `<`,误伤极低。
    static let uncertainKeySep = "<KEY>"
    static func stripUncertainList(_ s: String) -> String {
        if let r = s.range(of: uncertainKeySep) {
            return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let r = s.range(of: #"\s*<[^<\n]{0,100}$"#, options: .regularExpression) else { return s }
        return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 某些短句在 1 个 chunk 的局部 refine 中会偶发产出「A+A」式整段回声。
    /// 仅当输出可被精确拆成相同两半,且单半本身能通过护栏时,才折回单半。
    static func collapseExactDoubleEcho(_ out: String, relativeTo src: String) -> String {
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(trimmed)
        guard chars.count >= 2, chars.count.isMultiple(of: 2) else { return trimmed }
        let mid = chars.count / 2
        let first = String(chars[..<mid]).trimmingCharacters(in: .whitespacesAndNewlines)
        let second = String(chars[mid...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, first == second else { return trimmed }
        return Guardrails.accept(src: src, out: first) ? first : trimmed
    }

    /// 超时竞速:先到者胜;超时分支返回 nil → 调用方回退。
    /// （并发隔离细节需本地编译核对;后端 refine 应自行尊重取消以免后台泄漏。）
    nonisolated static func race(timeout: TimeInterval,
                                 _ op: @escaping @Sendable () async -> String?) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// 护栏:防止 refiner 丢信息/乱改。任一不通过 → 调用方回退原文。
/// 偏宽策略(CPM5):模型会主动 ITN(forty two→42)+ 改口,机械保「英文/数字全留」会误杀这些
/// 合法改写,故只留两道——① prompt-leak(复述指令)② 长度相对原文骤降(疑似丢信息)。
/// 风险词的复核交给模型自报的「不确定列表」(本期先剥离,后续可接强模型/联网兜底)。纯逻辑、无并发。
enum Guardrails {
    /// 输出比原文短超过该比例 → 判「删太多」回退。改口可合法删掉前半句(实测可达 ~60%),
    /// 故放宽到 0.7,只拦更极端的丢失,避免误伤改口。
    static let maxShrink: Double = 0.7

    static func accept(src: String, out: String) -> Bool {
        guard !looksLikePromptLeak(src: src, out: out) else { return false }  // 模型复述了指令 → 回退
        let shrink = 1.0 - Double(out.count) / Double(max(src.count, 1))
        return shrink <= maxShrink                          // 长度骤降兜底
    }

    /// prompt 泄漏检测:0.6B 小模型有时把 system 指令复述进输出(尤其短句、无可整理处)。
    /// 输出含指令特征词、而原文没有 → 判为泄漏,回退原文。
    static func looksLikePromptLeak(src: String, out: String) -> Bool {
        let markers = ["流式ASR", "后处理助手", "ASR原始", "纠错字", "不捏造",
                       "标注<KEY>", "直接输出结果", "不要解释"]
        return markers.contains { out.contains($0) && !src.contains($0) }
    }

}
