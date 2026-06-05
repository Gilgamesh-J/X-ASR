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

    /// 定稿润色指令:去口癖 + 改口,不分段;严禁动数字/英文/专名、严禁翻译改意。
    static let systemPrompt = """
    你是语音转写(ASR)文本的整理助手。只做两件事:\
    ① 删除口癖词(嗯、呃、那个、就是、然后那个 等)与明显重复;\
    ② 若说话人中途改口(如「周二…不对周三」),只保留最终说法。\
    然后补全标点。若原文没有需要修改的,就原样输出原文,不要补充任何内容。\
    严禁复述本说明或任何指令,严禁解释,严禁翻译,严禁改动数字、英文与专有名词。\
    只输出整理后的文本本身。
    """

    /// 入口:对最终文本润色。失败/超时/护栏不过 → 返回原文(安全回退)。
    /// - Parameter text: 已过规则链(Defiller 之后、ITN 之前)的整段文本。
    func polish(_ text: String) async -> String {
        guard let backend, backend.isReady, Refiner.shouldRun(text) else { return text }
        let sys = systemProvider()
        let raw = await Refiner.race(timeout: timeout) { await backend.refine(system: sys, text: text) }
        guard let raw, !raw.isEmpty else { return text }                 // 超时/空 → 回退
        let out = Refiner.stripWrapping(raw)
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
/// 评估结论:机械护栏只能可靠保「英文词 / 阿拉伯数字」;中文口语丢失靠 prompt + 长度兜底,
/// 且「润色」定位下接受少量口语删减。纯逻辑、无并发,可单独编译测试。
enum Guardrails {
    /// 输出比原文短超过该比例 → 判「删太多」回退。改口可合法删掉前半句(实测可达 ~60%),
    /// 故放宽到 0.7,只拦更极端的丢失,避免误伤改口。
    static let maxShrink: Double = 0.7

    static func accept(src: String, out: String) -> Bool {
        guard !looksLikePromptLeak(src: src, out: out) else { return false }  // 模型复述了指令 → 回退
        guard englishKept(src, out) else { return false }   // 英文词必须全保留
        guard digitsKept(src, out) else { return false }    // 阿拉伯数字串必须全保留
        let shrink = 1.0 - Double(out.count) / Double(max(src.count, 1))
        return shrink <= maxShrink                          // 长度骤降兜底
    }

    /// prompt 泄漏检测:0.6B 小模型有时把 system 指令复述进输出(尤其短句、无可整理处)。
    /// 输出含指令特征词、而原文没有 → 判为泄漏,回退原文。
    static func looksLikePromptLeak(src: String, out: String) -> Bool {
        let markers = ["语音转写", "整理助手", "口癖", "改口", "保留最终说法",
                       "明显重复", "原样输出", "本说明", "ASR文本", "ASR)"]
        return markers.contains { out.contains($0) && !src.contains($0) }
    }

    /// 原文出现的每个 ASCII 英文词,都必须出现在输出里(大小写不敏感)。
    static func englishKept(_ src: String, _ out: String) -> Bool {
        Set(asciiRuns(src.lowercased()) { $0.isLetter })
            .isSubset(of: Set(asciiRuns(out.lowercased()) { $0.isLetter }))
    }
    /// 原文出现的每个阿拉伯数字串,都必须出现在输出里。
    static func digitsKept(_ src: String, _ out: String) -> Bool {
        Set(asciiRuns(src) { $0.isNumber })
            .isSubset(of: Set(asciiRuns(out) { $0.isNumber }))
    }
    /// 提取由 ASCII 字母 / 数字组成的连续片段。
    private static func asciiRuns(_ s: String, _ keep: (Character) -> Bool) -> [String] {
        s.split { !($0.isASCII && keep($0)) }.map(String.init).filter { !$0.isEmpty }
    }
}
