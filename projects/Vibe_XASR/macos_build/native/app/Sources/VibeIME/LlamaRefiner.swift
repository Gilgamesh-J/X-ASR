// 仅在 VIBE_LLAMA 构建标志下编译(见 Package.swift)。缺 libllama / 未开标志时,本文件为空,
// 整体 app 照常构建,Refiner.backend 保持 nil → AI 润色 Beta 开关为安全 no-op。
#if VIBE_LLAMA
import Foundation
import CLlama

// llama.cpp 后端 —— AI 润色(Beta)的默认实现。
// =========================================================================
// 加载 GGUF refiner 模型,对整段文本做一次贪心(温度 0)"润色"推理。
//
// 线程模型:推理全部串行到一个专用 DispatchQueue;model/context 不跨线程并发使用,
//   故标 @unchecked Sendable(满足 RefinerBackend: Sendable)。
//
// ⚠️ 不可在本仓环境编译验证(需 native/llama 的 libllama + 整体 swift build)。
//    llama.cpp 的 C API 跨版本会漂移(类似 CLAUDE.md 记的 sherpa C# API drift)。
//    以下按 2025 稳定版编写;若本地 llama.h 函数名不同,按实际微调,流程不变。常见别名:
//      llama_model_load_from_file ↔ llama_load_model_from_file
//      llama_init_from_model      ↔ llama_new_context_with_model
final class LlamaRefiner: RefinerBackend, @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.xasr.vibexasr.refiner.llama")
    private let model: OpaquePointer        // llama_model*
    private let vocab: OpaquePointer        // llama_vocab*
    private let nThreads: Int32
    private let maxNewTokens: Int32

    /// 构造成功即就绪;失败走 init? → nil → 门面 backend=nil → 安全 no-op。
    var isReady: Bool { true }

    init?(modelPath: String, threads: Int = 4, maxNewTokens: Int = 512) {
        guard FileManager.default.fileExists(atPath: modelPath) else { return nil }
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 999                 // Apple Silicon:全部层上 Metal
        guard let m = llama_model_load_from_file(modelPath, mp) else {
            llama_backend_free(); return nil
        }
        guard let v = llama_model_get_vocab(m) else {
            llama_model_free(m); llama_backend_free(); return nil
        }
        self.model = m
        self.vocab = v
        self.nThreads = Int32(threads)
        self.maxNewTokens = Int32(maxNewTokens)
    }

    deinit {
        llama_model_free(model)
        llama_backend_free()
    }

    // MARK: RefinerBackend

    func refine(system: String, text: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            queue.async { [self] in
                cont.resume(returning: runInference(system: system, text: text))
            }
        }
    }

    // MARK: inference (serial queue)

    private func runInference(system: String, text: String) -> String? {
        guard let prompt = buildPrompt(system: system, user: text) else { return nil }

        // 每段一个全新 context(短文本,开销可忽略;避免跨段 KV 残留)。
        var cp = llama_context_default_params()
        cp.n_ctx = 2048
        cp.n_threads = nThreads
        cp.n_threads_batch = nThreads
        guard let ctx = llama_init_from_model(model, cp) else { return nil }
        defer { llama_free(ctx) }

        var tokens = tokenize(prompt, addSpecial: true)
        guard !tokens.isEmpty else { return nil }

        // 贪心采样链(温度 0:确定、可复现)。
        guard let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { return nil }
        defer { llama_sampler_free(smpl) }
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy())

        // 1) decode prompt —— 必须在 token 缓冲的有效作用域内 decode(指针生命周期坑)。
        let promptOK = tokens.withUnsafeMutableBufferPointer { buf -> Bool in
            llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count))) == 0
        }
        guard promptOK else { return nil }

        // 2) 贪心生成:逐 token,累积「字节」(中文常跨多 token,逐 token 解码会乱码)。
        var bytes = [UInt8]()
        var nGen: Int32 = 0
        while nGen < maxNewTokens {
            let tok = llama_sampler_sample(smpl, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            bytes.append(contentsOf: pieceBytes(tok))
            nGen += 1
            var one = tok
            let ok = withUnsafeMutablePointer(to: &one) { p in
                llama_decode(ctx, llama_batch_get_one(p, 1)) == 0
            }
            if !ok { break }
        }
        let out = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    // MARK: helpers

    /// 用模型自带 chat template(Qwen3)拼 system+user,返回可直接 tokenize 的 prompt。
    private func buildPrompt(system: String, user: String) -> String? {
        var msgs = [
            llama_chat_message(role: strdup("system"), content: strdup(system)),
            llama_chat_message(role: strdup("user"),   content: strdup(user)),
        ]
        defer {
            for m in msgs {
                free(UnsafeMutableRawPointer(mutating: m.role))
                free(UnsafeMutableRawPointer(mutating: m.content))
            }
        }
        // tmpl=nil → 模型内置模板;add_ass=true → 追加 assistant 起始。先试 8KB,不够再扩。
        var buf = [CChar](repeating: 0, count: 8192)
        var n = llama_chat_apply_template(nil, &msgs, msgs.count, true, &buf, Int32(buf.count))
        guard n > 0 else { return nil }
        if Int(n) > buf.count {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(nil, &msgs, msgs.count, true, &buf, Int32(buf.count))
            guard n > 0 else { return nil }
        }
        return String(cString: buf)
    }

    private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
        let byteLen = Int32(text.utf8.count)
        let cap = byteLen + 16
        var toks = [llama_token](repeating: 0, count: Int(cap))
        let n = text.withCString {
            llama_tokenize(vocab, $0, byteLen, &toks, cap, addSpecial, true)
        }
        guard n > 0 else { return [] }
        return Array(toks.prefix(Int(n)))
    }

    /// 单 token 的原始字节(不在此处 decode 成 String —— 交由调用方累积后统一 UTF-8 解码)。
    private func pieceBytes(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }
}
#endif
