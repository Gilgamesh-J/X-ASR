<h1 align="center">🎙️ X-ASR 系列</h1>

<p align="center">
  <b>基于 icefall/k2、Zipformer 和 sherpa-onnx 的流式语音识别模型系列。</b>
</p>

<p align="center">
  <b>参与机构</b>
</p>

<p align="center">
  <img src="assets/institutions/institutions-zh.png" width="900" alt="参与机构：上海交通大学、上海创智学院、复旦大学、华中科技大学">
</p>

<p align="center">
  <b>🌐 <a href="README.md">English</a></b>
</p>

<p align="center">
  <a href="https://huggingface.co/GilgameshWind/icefall_X_ASR_streaming">🤗 Hugging Face</a> |
  <a href="https://stream-asr.sjtuxlance.com/">🎧 在线 Demo</a> |
  <a href="X-ASR-zh-en/deployment/README.md">🚀 部署文档</a>
</p>

<p align="center">
  <b>📄 X-ASR-zh-en 工作报告：Coming Soon</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Model%20Released-X--ASR--zh--en-blue" alt="Model released">
  <img src="https://img.shields.io/badge/Languages-zh%20%7C%20en-green" alt="Languages">
  <img src="https://img.shields.io/badge/Streaming-low%20latency%20%7C%20multi--mode-orange" alt="Streaming">
  <img src="https://img.shields.io/badge/Deployment-sherpa--onnx-red" alt="Deployment">
  <img src="https://img.shields.io/badge/许可证-Apache--2.0-lightgrey" alt="License">
</p>

<p align="center">
  <a href="#项目概览">🔍 项目概览</a> |
  <a href="#时间线">📅 时间线</a> |
  <a href="#模型发布">📦 模型发布</a> |
  <a href="#评测结果">📊 评测结果</a> |
  <a href="#快速开始">🚀 快速开始</a>
</p>

---

<a id="项目概览"></a>

## 🔍 项目概览

### 🧩 X-ASR

**X-ASR** 是一个基于 **icefall** 框架构建的自动语音识别模型系列，重点面向 **流式 ASR** 和 **低延迟部署**，同时支持离线识别。当前仓库释放的是第一批 **中英文流式 ASR 模型**，后续 X-ASR 系列会围绕 **语言覆盖**、**模型架构** 和 **训练数据** 持续维护、更新与扩展。

### 🤖 X-ASR-zh-en

**X-ASR-zh-en** 基于约 **100 万小时**开源及收集语音数据训练。模型设计为采用 **Zipformer 架构** 的 **离线-流式一体化 transducer ASR 模型**，同时支持 **离线解码** 和 **真流式解码**。该模型提供多个流式 chunk size：**160 ms**、**480 ms**、**960 ms** 和 **1920 ms**，支持 **标点与大小写**，并可基于 **sherpa-onnx** 便捷部署。

<p align="center">
  <img src="assets/figures/zipformer.png" width="700" alt="Zipformer architecture">
</p>

<a id="时间线"></a>

## 📅 时间线

| 状态 | 事项 | 说明 |
|:---:|:---:|:---:|
| ✅ 已发布 | `X-ASR-zh-en` 初始版本 | 已发布中英文离线-流式一体化 ASR 模型、sherpa-onnx 部署文件和在线 Demo。 |
| 📄 Coming Soon | `X-ASR-zh-en` 工作报告 | 将补充训练方案、模型结构、评测协议、部署细节和消融分析。 |
| 🌏 近期计划 | 泰语、印尼语、越南语 ASR | 下一批流式 ASR 语言模型正在准备中。 |
| 🔄 持续迭代 | 模型与数据更新 | 持续优化模型 scaling、架构改进、数据 refine、延迟、稳定性、标点和大小写。 |

<a id="模型发布"></a>

## 📦 模型发布

| 模型 | 语言 | 类型 | 流式 chunk | 部署 | 工作报告 | 模型文件 |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `X-ASR-zh-en` | 中文、英文 | 离线-流式一体化 transducer ASR | 160 ms, 480 ms, 960 ms, 1920 ms | sherpa-onnx | **Coming Soon** | [GitHub](X-ASR-zh-en/deployment), [Hugging Face](https://huggingface.co/GilgameshWind/icefall_X_ASR_streaming) |

## ⭐ 核心特性

| 类别 | 说明 |
|:---:|:---:|
| **训练框架** | icefall / k2 |
| **模型架构** | Zipformer transducer |
| **训练规模** | 约 100 万小时开源及收集语音数据 |
| **当前语言** | 中文、英文 |
| **解码模式** | 离线解码与真流式解码 |
| **流式 chunk** | 160 ms, 480 ms, 960 ms, 1920 ms |
| **文本输出** | 支持标点和大小写 |
| **部署运行时** | sherpa-onnx |
| **接口形式** | WebSocket 流式服务端和 WAV 文件测试客户端 |

<a id="评测结果"></a>

## 📊 评测结果

以下结果对应当前 **X-ASR-zh-en** 版本。表中数值为 **WER/CER 百分比**，越低越好。所有结果均使用 **greedy search**。

<table>
  <thead>
    <tr>
      <th align="center" rowspan="2">模式</th>
      <th align="center" rowspan="2">Chunk size</th>
      <th align="center" colspan="2">LibriSpeech</th>
      <th align="center" rowspan="2">GigaSpeech</th>
      <th align="center" colspan="2">WenetSpeech</th>
    </tr>
    <tr>
      <th align="center">clean</th>
      <th align="center">other</th>
      <th align="center">net</th>
      <th align="center">meeting</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td align="center">Streaming</td>
      <td align="center">160 ms</td>
      <td align="center">3.91</td>
      <td align="center">10.17</td>
      <td align="center">10.97</td>
      <td align="center">9.45</td>
      <td align="center">12.04</td>
    </tr>
    <tr>
      <td align="center">Streaming</td>
      <td align="center">480 ms</td>
      <td align="center">3.14</td>
      <td align="center">7.57</td>
      <td align="center">9.77</td>
      <td align="center">7.38</td>
      <td align="center">9.31</td>
    </tr>
    <tr>
      <td align="center">Streaming</td>
      <td align="center">960 ms</td>
      <td align="center">3.12</td>
      <td align="center">7.22</td>
      <td align="center">9.62</td>
      <td align="center">6.96</td>
      <td align="center">8.84</td>
    </tr>
    <tr>
      <td align="center">Streaming</td>
      <td align="center">1920 ms</td>
      <td align="center">2.84</td>
      <td align="center">6.47</td>
      <td align="center">9.46</td>
      <td align="center">6.42</td>
      <td align="center">8.03</td>
    </tr>
    <tr>
      <td align="center">Offline</td>
      <td align="center">-</td>
      <td align="center"><b>2.69</b></td>
      <td align="center"><b>5.76</b></td>
      <td align="center"><b>9.23</b></td>
      <td align="center"><b>5.96</b></td>
      <td align="center"><b>7.20</b></td>
    </tr>
  </tbody>
</table>

**说明：** 加粗数值表示该评测列中当前列出的最佳结果。

## 🎧 Demo

基于 **sherpa-onnx** 的在线 Demo：

- [https://stream-asr.sjtuxlance.com/](https://stream-asr.sjtuxlance.com/)

Demo 视频：

<a href="assets/demos/demo.mov">
  <img src="assets/figures/demo-preview.png" width="700" alt="X-ASR demo video preview">
</a>

[打开 Demo 视频](assets/demos/demo.mov)

<a id="快速开始"></a>

## 🚀 快速开始

### 1. 克隆仓库

本仓库使用 **Git LFS** 管理 ONNX 模型文件和 demo 媒体文件。克隆或拉取大文件前需要先安装并初始化 Git LFS。

```bash
git lfs install
git clone https://github.com/Gilgamesh-J/X-ASR.git
cd X-ASR
git lfs pull
```

也可以从 Hugging Face 下载模型文件：

```bash
hf download GilgameshWind/icefall_X_ASR_streaming \
  --local-dir ./X-ASR-zh-en/deployment
```

### 2. 安装 Python 依赖

```bash
cd X-ASR-zh-en/deployment
python -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

### 3. 启动流式识别服务

下面示例使用 CPU 启动 **160 ms 流式模型**。

```bash
python infer_and_client/sherpa_streaming_server.py \
  --host 0.0.0.0 \
  --port 6666 \
  --tokens models/chunk-160ms-model/tokens.txt \
  --encoder models/chunk-160ms-model/encoder-160ms.onnx \
  --decoder models/chunk-160ms-model/decoder-160ms.onnx \
  --joiner models/chunk-160ms-model/joiner-160ms.onnx \
  --provider cpu \
  --sample-rate 16000 \
  --feature-dim 80 \
  --decoding-method greedy_search \
  --model-type zipformer2 \
  --text-format none
```

### 4. 使用 WAV 文件测试

另开一个终端：

```bash
cd X-ASR-zh-en/deployment
source .venv/bin/activate

python infer_and_client/sherpa_streaming_client.py \
  --server-uri ws://127.0.0.1:6666 \
  --wav /path/to/test.wav \
  --chunk-ms 100 \
  --simulate-realtime 1
```

客户端会将音频转换为 **16 kHz 单声道 int16 PCM**，通过 WebSocket 分块发送，并打印服务端返回的 partial/final 识别结果。

完整部署参数见 [X-ASR-zh-en/deployment/README.md](X-ASR-zh-en/deployment/README.md)。

## 🗂️ 仓库结构

```text
X-ASR/
|-- README.md
|-- README_zh.md
|-- LICENSE
|-- assets/
|   |-- figures/
|   |   |-- demo-preview.png
|   |   `-- zipformer.png
|   `-- demos/
|       `-- demo.mov
`-- X-ASR-zh-en/
    `-- deployment/
        |-- README.md
        |-- requirements.txt
        |-- infer_and_client/
        |   |-- sherpa_streaming_infer.py
        |   |-- sherpa_streaming_server.py
        |   `-- sherpa_streaming_client.py
        `-- models/
            |-- chunk-160ms-model/
            |-- chunk-480ms-model/
            |-- chunk-960ms-model/
            `-- chunk-1920ms-model/
```

## 🤝 贡献

欢迎围绕以下方向反馈或贡献：

- 不同 CPU/GPU 环境下的部署问题
- 流式延迟和稳定性反馈
- 新数据集或新领域上的评测结果
- 新语言或后续发布需求
- 文档和示例改进

如果反馈部署问题，请提供 **运行环境**、**执行命令**、**输入音频格式** 和 **错误日志**。

## 📜 许可证

本项目使用 **Apache-2.0 License**。

## 🙏 致谢

本模型系列基于 **icefall** 训练，并使用 **sherpa-onnx** 部署。

- icefall: https://github.com/k2-fsa/icefall
- sherpa-onnx: https://github.com/k2-fsa/sherpa-onnx
