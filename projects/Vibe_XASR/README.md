# Vibe XASR — 本地语音输入法 / Local Voice Input

> X-ASR 引擎的官方桌面应用(macOS + Windows)。按住热键说话,文字直接落到光标处。**100% 本地、离线,数据不出设备。**
>
> The official desktop app for the **X-ASR** engine. Hold a hotkey, speak, and text lands at your cursor — **100% local & offline.**

## 功能 / Features

- **三种听写模式**:一次性插入 / 逐字流式 / OnCall 持续候机
- **按住即说**:全局热键按下听写、松开上屏
- **中英文自由说**:中英混说无缝切换,实时上屏
- **便签 + 历史记录**:按日期保存,复制 / 编辑 / 导出
- **多语言界面**:中 / 英 / 日 / 韩,默认跟随系统
- **隐私优先**:全程离线

## 下载 / Download

到 **[X-ASR Releases](https://github.com/Gilgamesh-J/X-ASR/releases)** 下载已签名公证的安装包。
macOS 版需要 **macOS 15 (Sequoia)+**(Universal,Apple Silicon 与 Intel 通用)。

## 构建 / Build

> ⚠️ 本目录仅含**源码**。预编译原生依赖(sherpa-onnx / onnxruntime 的 `*.dylib` / `*.dll`)与 VAD 模型(`*.onnx`)**未纳入版本库**,需用脚本获取/编译;ASR 模型从 HuggingFace [`GilgameshWind/X-ASR-zh-en`](https://huggingface.co/GilgameshWind/X-ASR-zh-en) 获取。

**macOS**(`macos_build/`)
1. `native/sherpa/build.sh` — 编译 sherpa-onnx 原生库
2. `native/app/build_app.sh` — 构建 App(`ASR_SRC=<X-ASR 模型目录>`)
3. `package_release.sh` — Developer ID 签名 + 公证 + 打包 dmg/zip + 生成 Sparkle appcast

**Windows**(`windows_build/`):见 `windows_build/README.md`。

## 致谢 / Credits

基于 [X-ASR](https://github.com/Gilgamesh-J/X-ASR) · [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) ·
[FireRedVAD](https://github.com/FireRedTeam/FireRedVAD) · [silero-vad](https://github.com/snakers4/silero-vad) ·
[onnxruntime](https://github.com/microsoft/onnxruntime) · [Sparkle](https://github.com/sparkle-project/Sparkle)
