#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Qwen3-refiner-0.6B-MLX 离线质量评估  (Vibe XASR ·「大模型整理」Beta 的前置评估)
=====================================================================
目的:在 Apple Silicon 本地用 mlx-lm 跑 MuyuanJ/Qwen3-refiner-0.6B-MLX,验证三件事——
      ① 去口癖/顺滑  ② 改口/自我纠正  ③ 列表/分段——0.6B 能不能稳,以及护栏能不能
      拦住丢信息。据此决定是否值得集成进 Vibe XASR(macOS),并给 Swift 集成定稿 prompt + 护栏。

      —— 这是评估脚本,不属于 app,只在 macOS(Apple Silicon)跑。

护栏说明:
  · token 保全只保「英文词 / 阿拉伯数字」(这些几乎不该因整理而消失)。
  · 「改口纠正」会故意删掉改口前的内容,与「token 全保留」天然冲突,所以中文信息的
    丢失无法机械判定 —— 只能靠 prompt 质量 + 人工看 diff。脚本对中文丢失只能提示、不能断言。

依赖:  pip install mlx-lm modelscope
用法:
    python eval_refiner.py --show-diff               # 内置样本,看清每句改了什么
    python eval_refiner.py --input my_asr.txt         # 每行一句你的真实听写输出
    python eval_refiner.py --prompt-style plain        # 切换 plain/tidy/loose
"""
from __future__ import annotations
import argparse
import difflib
import re
import sys
import time

MODEL_ID = "MuyuanJ/Qwen3-refiner-0.6B-MLX"

PROMPT_STYLES = {
    # 不加 system,直接把原文当 user 输入(贴近纯 SFT 训练分布)
    "plain": None,
    # 统一整理(集成建议用这套):去口癖 + 改口 + 分段 + 标点,强约束不动数字/英文/专名/语义
    "tidy": (
        "你是语音转写(ASR)文本的整理助手。请做且只做两件事:"
        "① 删除口癖词(嗯、呃、那个、就是、然后那个 等)与明显重复;"
        "② 若说话人中途改口(如「周二…不对周三」),只保留最终说法。"
        "然后补全标点,使句子通顺。"
        "除了口癖和被改口替换掉的部分,不许删除任何有信息量的内容——"
        "任何完整的分句、短语、语气都要逐字保留(尤其疑问、祈使、嘱咐,如「你看一下」「记得」)。"
        "严禁改变原意,严禁翻译,严禁改动数字、英文单词与专有名词。"
        "只输出整理后的文本,不要解释、不要加引号。"
    ),
    # 宽松:允许更自由润色,用来对比 tidy 是否压制了有用修正
    "loose": (
        "请把下面这段语音转写文本整理得更通顺自然:去掉口头语和重复、采纳改口后的最终说法、"
        "并列内容分行列出、补全标点。只输出整理后的文本。"
    ),
}

# 内置评估集:按三个目标功能分组 + 陷阱句(数字/专名/已干净)
DEFAULT_SAMPLES = [
    # —— ① 去口癖 / 顺滑 ——
    "嗯那个我今天那个想说的就是就是我们这个项目啊它的进度有点慢",
    "然后然后我们就去那个吃饭了对吧就是楼下那家",
    # —— ② 改口 / 自我纠正(期望删掉改口前的说法)——
    "我们周二开会啊不对是周三下午两点开会",          # 期望:删「周二」,留「周三下午两点」
    "把文件发给张三呃不对发给李四吧",                  # 期望:删「张三」,留「李四」
    "价格是三百块呃不对是三百五十块",                  # 期望:留「三百五十块」
    # —— ③ 列表 / 分段 ——
    "今天要做三件事第一写周报第二改那个登录的bug第三下午开评审会",  # 期望:分 3 点
    "帮我买点东西牛奶鸡蛋还有面包",                    # 期望:列举分行
    # —— 陷阱:数字 / 专名 / 已干净 ——
    "把音量调到百分之七十然后温度设成二十六度",        # 数字应原样
    "我们用的是 sherpa onnx 这个框架跑 zipformer 模型", # 专名/英文应原样
    "这个 PR 我 review 完了就是有几个 comment 你看一下", # 英文保留 + 不许丢「你看一下」
    "明天上午九点开会,请提前准备好材料。",            # 已干净 → 改动应≈0
]

THINK_RE = re.compile(r"<think>.*?</think>", re.S | re.I)


def eprint(*a):
    print(*a, file=sys.stderr)


def load_model(model_id):
    try:
        from modelscope import snapshot_download
    except ImportError:
        eprint("缺少 modelscope:pip install modelscope"); sys.exit(1)
    try:
        from mlx_lm import load
    except ImportError:
        eprint("缺少 mlx-lm:pip install mlx-lm(仅 Apple Silicon)"); sys.exit(1)
    eprint(f"↓ 下载 / 定位模型 {model_id} …")
    local = snapshot_download(model_id)
    eprint(f"  本地路径:{local}")
    return load(local)


def build_prompt(tokenizer, text, system):
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": text})
    kw = dict(add_generation_prompt=True, tokenize=False)
    try:
        return tokenizer.apply_chat_template(messages, enable_thinking=False, **kw)
    except TypeError:
        return tokenizer.apply_chat_template(messages, **kw)


def gen(model, tokenizer, prompt, max_tokens):
    from mlx_lm import generate
    try:
        from mlx_lm.sample_utils import make_sampler
        sampler = make_sampler(temp=0.0)
        return generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens,
                        sampler=sampler, verbose=False)
    except (ImportError, TypeError):
        try:
            return generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens,
                            temp=0.0, verbose=False)
        except TypeError:
            return generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens, verbose=False)


def clean(out):
    out = THINK_RE.sub("", out)
    return out.strip().strip('"“”\'').strip()


def protect_check(src, out):
    """token 保全护栏:返回(丢失的英文词, 丢失的阿拉伯数字)。中文丢失无法机械判定,不在此列。"""
    se, oe = set(re.findall(r"[A-Za-z]+", src.lower())), set(re.findall(r"[A-Za-z]+", out.lower()))
    sd, od = set(re.findall(r"\d+", src)), set(re.findall(r"\d+", out))
    return sorted(se - oe), sorted(sd - od)


def char_diff(a, b):
    parts = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b).get_opcodes():
        if op == "equal":
            parts.append(a[i1:i2])
        elif op == "delete":
            parts.append(f"[-{a[i1:i2]}-]")
        elif op == "insert":
            parts.append(f"{{+{b[j1:j2]}+}}")
        elif op == "replace":
            parts.append(f"[-{a[i1:i2]}-]{{+{b[j1:j2]}+}}")
    return "".join(parts)


def main():
    ap = argparse.ArgumentParser(description="Qwen3-refiner-0.6B-MLX 离线质量评估")
    ap.add_argument("--model", default=MODEL_ID)
    ap.add_argument("--input", help="文本文件,每行一句待整理的听写输出")
    ap.add_argument("--prompt-style", choices=list(PROMPT_STYLES), default="tidy")
    ap.add_argument("--revert-threshold", type=float, default=0.55,
                    help="改动率超过该值视为可疑(分段会拉高改动率,故阈值放宽)")
    ap.add_argument("--max-tokens", type=int, default=384)
    ap.add_argument("--show-diff", action="store_true")
    args = ap.parse_args()

    samples = DEFAULT_SAMPLES
    if args.input:
        with open(args.input, encoding="utf-8") as f:
            samples = [l.strip() for l in f if l.strip()]

    system = PROMPT_STYLES[args.prompt_style]
    model, tokenizer = load_model(args.model)
    eprint(f"✓ 模型就绪;prompt = {args.prompt_style};共 {len(samples)} 句\n")

    changes, reverts, guard_hits, t0 = [], 0, 0, time.time()
    for i, src in enumerate(samples, 1):
        out = clean(gen(model, tokenizer, build_prompt(tokenizer, src, system), args.max_tokens))
        change = 1 - difflib.SequenceMatcher(None, src, out).ratio()
        changes.append(change)
        flags = []
        if change > args.revert_threshold:
            reverts += 1
            flags.append("⚠️改动过大→回退")
        miss_eng, miss_dig = protect_check(src, out)
        if miss_eng or miss_dig:
            guard_hits += 1
            if miss_eng:
                flags.append(f"⚠️丢英文:{','.join(miss_eng)}")
            if miss_dig:
                flags.append(f"⚠️丢数字:{','.join(miss_dig)}")
        print(f"[{i}] 改动率 {change*100:4.1f}%  {'  '.join(flags)}")
        print(f"  原: {src}")
        print(f"  修: {out}")
        if args.show_diff:
            print(f"  Δ : {char_diff(src, out)}")
        print()

    n = len(samples) or 1
    dt = time.time() - t0
    print("─" * 64)
    print(f"汇总:{len(samples)} 句 | 平均改动率 {sum(changes)/n*100:.1f}% | "
          f"改动过大 {reverts} | 英文/数字护栏命中 {guard_hits} | {dt:.1f}s ({dt/n:.2f}s/句)")
    print("\n人工重点看:")
    print("  ② 改口三句:有没有正确删掉改口前的(周二/张三/三百块),且没误删别的")
    print("  ③ 列表两句:有没有合理分行,且没增删事项")
    print("  陷阱:数字/百分比、sherpa onnx/PR/review、『你看一下』——有没有被改/丢")
    print("  『明天上午九点开会』:改动率应≈0,否则是幻觉")


if __name__ == "__main__":
    main()
