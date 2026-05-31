# X-ASR Live Demo

[English](./README.md) | 中文

![流式语音输入演示](./assets/streaming-demo.gif)

> 中英混说,partial 原地流式刷新、光标实时右移,一停顿即定稿上屏。

一个**开箱即跑的本地端到端流式语音识别 demo**:麦克风/wav → **VAD 切句** → X-ASR 流式 zipformer 边说边出字 → 打印 partial / final + 延迟。

X-ASR 的流式 ASR 很强,但解码器本身**不做端点检测**——它不知道"一句话在哪结束"。本 demo 在前面接一层 **VAD 门控 + 句子端点**,补上这块,并提供 **3 个可插拔的 VAD 后端**;无需起服务,插上麦克风 30 秒即可体验全链路低延迟。

> 与现有 `deployment/`(WebSocket server/client)互补:那是服务端流式;这是**本地、零服务、带断句**的最小闭环,也方便排模型/延迟坑。

## 初衷

把 **VAD(语音端点)+ 流式 ASR** 这两块拼起来,就是一个**完全纯本地、离线、隐私不出设备**的语音输入底座。

本示例想说明的正是:有了这条链路,你可以**很快搭出一个纯本地的语音输入法 / 实时听写**——说话即出字、自动断句上屏,全程不连网、不调云端 API、数据不离开本机。

关键件 demo 里已经齐了:VAD 决定"一句话何时开始/结束"、流式 zipformer 边说边出字、preroll 补句首、下降沿端点收句。把 `[final]` 的回调从"打印"换成"注入当前输入框 / IME",就是一个可用的本地语音输入法雏形。

## 流式输入演示

流式的本质是**边说边出字**:partial 随语音逐词**原地刷新**,光标 `▌` 实时跟在最新字尾右移;一停顿即定稿成 `[final]` 上屏。中英混说(code-switch)也能无缝流过:

```text
说:   “这个 streaming demo 真的很 smooth，中英混说也能 real-time 出字。”

t+0.3s   [partial] 这个▌
t+0.8s   [partial] 这个 streaming demo▌
t+1.5s   [partial] 这个 streaming demo 真的很 smooth▌
t+2.2s   [partial] 这个 streaming demo 真的很 smooth，中英混说也能▌
         ── 检测到停顿 → 收句 ──
t+2.6s   [final  ] 这个 streaming demo 真的很 smooth，中英混说也能 real-time 出字。   (finalize 38ms, seg 2.4s, RTF 0.02)
```

同一行原地刷新(`\r` + 单行、按显示宽度截断,中文算 2 列),光标 `▌` 始终钉在最新字尾——不换行、不刷屏。把这个 `[final]` 接到输入框,就是一个**边说边上屏**的本地语音输入法。

## 特性

- **三种可插拔 VAD**,同一套 `run()` 循环,鸭子类型切换:
  - `firered`(**默认**)—— [FireRedVAD](https://github.com/FireRedTeam/FireRedVAD)(DFSMN 流式,0.6M 参数,FLEURS-VAD-102 上 F1 97.57%,公开报告优于 Silero/TEN/FunASR/WebRTC,Apache-2.0)。**未安装或缺权重时自动降级到 silero**,demo 永不罢工。
  - `silero` —— sherpa-onnx 内置 silero VAD,仅依赖 `sherpa-onnx`,鲁棒。
  - `energy` —— 教学版纯 Python 能量门限,**零模型零额外依赖**,代码即原理。
- **可靠的句子端点**:用 VAD 的"说话→停顿"下降沿收句(`is_speech_detected()`),不依赖实时流里不稳定的段队列,**连续多句不卡**。
- **句首回补(preroll)**:补回 VAD 起音延迟吃掉的开头,避免每句开头漏字(`--preroll`)。
- **干净的单行刷新**:partial 按终端宽度截断、中文按 2 列宽计算,**长句不刷屏、随窗口自适应**。
- **中文去空格规范化** + 标点(沿用 X-ASR deployment 的处理)。
- 麦克风实时(M1)/ wav 文件(M0)两种输入,CPU 或 CoreML provider。

## 安装

```bash
# 核心(silero / energy 即可跑)
pip install -r requirements.txt

# 可选:启用默认的 FireRedVAD
pip install -r requirements-firered.txt

# 下载权重:ASR(X-ASR-zh-en chunk-960ms)+ silero +(可选)FireRedVAD
./download_models.sh
```

模型最终落到:
```
models/asr/{encoder,decoder,joiner}-960ms.onnx + tokens.txt   # X-ASR 流式 zipformer
models/silero_vad.onnx                                        # silero 后端
models/firered_vad/{model.pth.tar,cmvn.ark}                   # FireRedVAD(可选)
```

## 用法

```bash
# 推荐配置:默认 FireRedVAD + 稍大的句首回补(--provider cpu 即默认)
python live_asr.py --vad firered --preroll 1.0

# 实时麦克风(默认 FireRedVAD,缺失则自动降级 silero)
python live_asr.py

# 指定后端
python live_asr.py --vad silero
python live_asr.py --vad energy

# 喂 wav 先排模型/延迟坑(M0)
python live_asr.py --wav test.wav

# Apple Silicon CoreML 加速
python live_asr.py --provider coreml

# 列出麦克风设备
python live_asr.py --list-devices
```

常用调参:

| 参数 | 默认 | 作用 |
|---|---|---|
| `--vad` | `firered` | VAD 后端:`firered` / `silero` / `energy` |
| `--vad-min-silence` | `0.7` | 尾部静音多久判一句结束(秒);调大=少切碎 |
| `--vad-threshold` | `0.5` | silero / firered 的语音概率阈值 |
| `--preroll` | `0.7` | 句首回补(秒):漏字就调大 |
| `--tail-pad` | `1.0` | finalize 时补的尾部静音(秒),要 ≥ 流式 chunk 才不吃尾字 |
| `--energy-threshold` | `0.02` | energy 后端的 RMS 阈值 |

输出示例:

```
[VAD] FireRedVAD(DFSMN 流式)  threshold=0.5 min_silence=0.7s min_speech=0.25s
[麦克风] 说话吧 (Ctrl-C 退出)...
[final  ] 今天天气怎么样    (finalize 37ms, seg 1.8s, RTF 0.02)
```

## 端点检测是怎么做的(设计要点)

流式 transducer 边喂边出字,但"一句话结束"得由外部判定。本 demo 的 `run()`:

1. VAD 报"在说话" → 新建一个 recognizer stream,并把 **preroll 缓冲**(开流前 ~0.7s 的历史窗口)补喂进去,救回被起音延迟吃掉的句首;
2. 持续喂帧、解码、刷新 `[partial]`;
3. VAD 的 `is_speech_detected()` 由 **True→False** 的下降沿 = 句末静音已确认(已含 `min_silence` 滞后)→ 补 `--tail-pad` 尾静音、`input_finished()`、打印 `[final]`,回到待命等下一句。

> 关键点:**不靠 VAD 的内部段队列(`pop()`)来收句**。silero 在无限麦克风流里不保证自动吐段,靠它会卡在 partial 出不来 final;改用 `is_speech_detected()` 下降沿后,三种后端都能连续多句稳定收句。

## 换成你自己的模型

`models/asr/` 放任意 sherpa-onnx 兼容的流式模型即可(transducer 自动识别 encoder/decoder/joiner;wenet-ctc 单模型也支持),`run()` 循环与运行时都不用改。

## 致谢与许可

- **FireRedVAD** © FireRedTeam / 小红书,Apache-2.0 —— <https://github.com/FireRedTeam/FireRedVAD>(权重:HuggingFace `FireRedTeam/FireRedVAD` / ModelScope `xukaituo/FireRedVAD`)。本 demo 通过官方 `pip install fireredvad` 使用,不分发其代码或权重。
- **silero-vad** © Silero Team,MIT —— 经 sherpa-onnx 运行时调用。
- **sherpa-onnx** © k2-fsa,Apache-2.0。

本目录随 X-ASR 采用 **Apache-2.0**。
