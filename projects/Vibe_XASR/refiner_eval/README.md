# Refiner 评估(「大模型修正」Beta 前置验证)

用 MLX 在本地跑 [`MuyuanJ/Qwen3-refiner-0.6B-MLX`](https://modelscope.cn/models/MuyuanJ/Qwen3-refiner-0.6B-MLX),
评估它做 ASR 后处理修正的**质量与幻觉率**,据此决定是否值得集成进 Vibe XASR(macOS)。

> 这是**评估脚本,不属于 app**。仅 macOS(Apple Silicon)可跑。
> 先廉价地验证模型质量,过关再付昂贵的 Swift 集成成本。

## 环境

- macOS + Apple Silicon(M 系列)
- Python 3.9+

```bash
pip install mlx-lm modelscope
```

## 运行

```bash
# 内置样本(含口癖句 + 数字/专有名词「陷阱」句),默认 strict 提示
python eval_refiner.py

# 三种提示策略各跑一遍,挑出修正好、幻觉少的那种(模型卡没给官方模板,必须自己校准)
python eval_refiner.py --prompt-style plain
python eval_refiner.py --prompt-style strict
python eval_refiner.py --prompt-style loose

# 看清每句到底改了什么(删除标 [-x-],新增标 {+y+})
python eval_refiner.py --show-diff

# 喂你自己的真实听写输出(每行一句),最有说服力
python eval_refiner.py --input my_asr.txt --show-diff
```

## 怎么解读(决策标准)

脚本对每句给出**改动率**(字符级,1 − 相似度),并对改动过大的句子标记「应回退」——这正是
集成时防幻觉的护栏原型:**改动超阈值就丢弃修正、回退原文**。

判断「是否值得集成」,重点看这几类:

| 看什么 | 期望 | 不达标说明 |
|---|---|---|
| 本就干净的句子(如「明天上午九点开会」) | 改动率 ≈ 0 | 它在**画蛇添足 / 幻觉** |
| 数字 / 百分比 / 温度 | 原样不动 | 印证「ITN 别交给它」,集成时把数字段排除 |
| 专有名词 / 英文(sherpa onnx、PR、review) | 原样不动 | 会破坏专有名词 → 高风险 |
| 口癖 / 重复句 | 明显变顺、**不丢信息** | 这是它的核心价值,不达标就不值得做 |

经验门槛(供参考):**干净句改动率≈0、数字/专名零改错、口癖句明显改善** 三者同时满足,
才值得进入 Swift 集成阶段;否则先调 prompt,或判定该模型不适合。

## 下一步(过关之后)

集成进 [`macos_build`](../macos_build/) 时的设计要点(详见此前讨论):
默认关 + Beta 角标、按需下载模型、挂在后处理链**最后一环**、只做口癖/顺滑(**不接管 ITN**)、
带「改动率超阈值回退原文」护栏、不进实时插入路径(整段说完后再二次替换)。
MLX 是 Apple-only,Windows 对齐需另用 onnxruntime-genai / llama.cpp,Beta 阶段暂不还这笔账。
