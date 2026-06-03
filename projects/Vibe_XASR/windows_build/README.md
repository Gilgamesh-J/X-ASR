# Vibe XASR — Windows port

A Windows tray app that mirrors the macOS **Vibe XASR** voice-dictation app: hold a
global hotkey, speak, and the recognized **zh-en** text is inserted at the caret in
whatever app currently has focus. **100% local / offline.**

> **Status: implemented and compiles on Windows.** The full UI is built (a macOS-faithful
> Settings window with the 6-tab sidebar, History window, the menu-bar-style tray popup,
> the HUD + OnCall overlays, and a 4-language zh/en/ja/ko interface), the engine wiring is
> complete, and it publishes to a self-contained single-file `VibeXASR.exe` for **win-x64**
> and **win-arm64** (verified by launching and screenshotting each surface on Windows 11).
> All original `// TODO(win):` items have been resolved (see "Resolved" below).

## What it is

- **Tray (NotifyIcon) app**, no main window. Context menu: `Mode ▸ paste/type/oncall`,
  `History…`, `Settings…`, `Quit`.
- **Engine:** streaming zh-en ASR — sherpa-onnx **online/streaming zipformer2 transducer**,
  greedy decoding — plus a **VAD** (silero or FireRed). 16 kHz mono.
- **Three dictation modes** (same behavior as macOS):
  - `paste` — insert the whole result once, on hotkey release.
  - `type` — stream char-by-char to the caret (with backspace diffing as the hypothesis revises).
  - `oncall` — always-on, VAD-segmented; a borderless top-most overlay shows live text; copy manually.
- **Local history** as JSON in `%APPDATA%\VibeXASR\history.json`.
- **Settings** in `%APPDATA%\VibeXASR\settings.json` (mode, tier, hotkey, VAD, language).
- **4-language UI** (中 / EN / 日 / 한), live-switchable; `Auto` follows the system language.

## Prerequisites

- **Windows 10 or 11** (x64 or ARM64).
- **.NET 8 SDK** — https://dotnet.microsoft.com/download/dotnet/8.0
- A working microphone.

## NuGet packages (verify versions before building)

| Package | Referenced version | Purpose |
|---|---|---|
| `org.k2fsa.sherpa.onnx` | `1.10.32` | Streaming ASR + VAD; bundles the Windows native runtime (win-x64/arm64). |
| `NAudio` | `2.2.1` | WASAPI mic capture + resampling to 16 kHz mono. |

> **TODO(win):** run `dotnet restore` and confirm both versions resolve. If a version is
> unavailable, pick the latest stable on nuget.org and update `VibeXASR.Windows.csproj`.
> The sherpa-onnx C# **API field names** (config structs / type names) occasionally change
> between majors — if it doesn't compile, reconcile `Dictation/StreamingAsr.cs` and
> `Dictation/Vad.cs` against the installed version's samples.

## Fetch the models

Models are **not** in the repo. They are fetched on first launch from HuggingFace:

```
https://huggingface.co/GilgameshWind/X-ASR-zh-en/resolve/main/deployment/models/chunk-<T>ms-model/<file>
```

Per tier `<T>` ∈ {160, 480, 960, 1920} the files are:
`encoder-<T>ms.onnx`, `decoder-<T>ms.onnx`, `joiner-<T>ms.onnx`, `tokens.txt`.
Plus a VAD model (`silero_vad.onnx` or `fireredvad.onnx`).
**Default tier = 960 ms.** They are cached under `%APPDATA%\VibeXASR\models\`.

`Models/ModelDownloader.cs` does this with progress. You can also pre-download manually
into `%APPDATA%\VibeXASR\models\chunk-960ms-model\` to skip the first-run download.

> **TODO(win):** confirm the exact VAD asset path within the HF repo (the downloader assumes
> `.../models/vad/<file>`); adjust `VadFileUrl` if the layout differs.

## Build

From `windows_build/` in PowerShell:

```powershell
# both architectures into dist/
powershell -ExecutionPolicy Bypass -File .\build.ps1

# or a single RID
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Rids win-x64
```

Or by hand:

```powershell
dotnet publish src/VibeXASR.Windows -c Release -r win-x64   --self-contained -p:PublishSingleFile=true -o dist/win-x64
dotnet publish src/VibeXASR.Windows -c Release -r win-arm64 --self-contained -p:PublishSingleFile=true -o dist/win-arm64
```

The output is a self-contained single-file `VibeXASR.exe` (bundled .NET runtime + native
ONNX DLLs). Run it; a tray icon appears.

## Installer (bundles the default model — works offline immediately)

`installer/` builds a **per-user MSI** (`VibeXASR-Setup.msi`) that ships the app **plus the
default 960 ms model + VAD inside it**, so a fresh install needs no first-run download.

```powershell
# one-time: the free WiX v5 toolset (v6/v7 require a paid EULA)
dotnet tool install --global wix --version 5.0.2
wix extension add -g WixToolset.UI.wixext/5.0.2

cd installer
powershell -ExecutionPolicy Bypass -File .\build-installer.ps1   # -> installer\VibeXASR-Setup.msi (~670 MB)
```

The installer:
- installs to `%LOCALAPPDATA%\Programs\VibeXASR` — **per-user, no admin / no UAC**;
- bundles `models\chunk-960ms-model\*` + `models\silero_vad.onnx`; the app reads them from
  its install dir (like the macOS app reads `Resources/`), so it's **ready offline on first
  launch** (extra latency tiers still download on demand to `%APPDATA%\VibeXASR`);
- adds **Start-Menu + Desktop shortcuts** (with the app icon) and an Apps-list (uninstall)
  entry; install silently with `msiexec /i VibeXASR-Setup.msi /qn`.

The app icon is a real embedded multi-resolution `.ico` (`src/VibeXASR.Windows/appicon.ico`,
referenced via `<ApplicationIcon>`), so Explorer / shortcuts / the tray all show the mark.

> **VAD note:** the bundled VAD is **silero v4** — sherpa-onnx 1.10.x rejects silero **v5**
> with `Unsupported silero vad model`. (FireRedVAD on macOS uses a custom shim, not sherpa,
> so it isn't wired on Windows yet — Windows defaults to silero.)

## Using it (push-to-talk) & troubleshooting

- It's **push-to-talk**: **hold** the trigger key, **speak**, then **release** — the text is
  inserted into whatever window has focus (click into a text field first). A quick tap with no
  speech does nothing. The recognizer streams the *whole* hold (it does not gate on the VAD),
  so quiet speech still gets through.
- After launch, wait a moment for **就绪 / Ready** — the 565 MB model loads on a background
  thread (the UI and hotkey stay responsive). Pressing the key before it's ready shows a
  "model loading" tip rather than doing nothing.
- VAD on Windows is **silero** (FireRedVAD is a macOS-only shim; a stored `fire` setting
  coerces to silero so it can't break the engine).
- A diagnostic log is written to **`%APPDATA%\VibeXASR\log.txt`** (hook install / hotkey /
  engine ready / mic peak level / recognized text) — useful if dictation seems unresponsive.

## Parity vs macOS

| Concern | macOS app | This Windows skeleton |
|---|---|---|
| Shell | Menu-bar status item | Tray `NotifyIcon` + context menu |
| Global hotkey (push-to-talk hold) | CGEventTap / global monitor | `WH_KEYBOARD_LL` low-level keyboard hook (`GlobalHotkey.cs`) |
| Text insertion | Type Unicode, clear modifiers | `SendInput` + `KEYEVENTF_UNICODE`, clear modifiers (`Input/TextInserter.cs`) |
| Mic capture | AVAudioEngine → 16 kHz mono | NAudio WASAPI → mono → 16 kHz resample (`MicCapture.cs`) |
| ASR | sherpa-onnx online zipformer2 transducer, greedy | same, via `org.k2fsa.sherpa.onnx` (`Dictation/StreamingAsr.cs`) |
| VAD | silero / FireRed | same (`Dictation/Vad.cs`) |
| Modes | paste / type / oncall | paste / type / oncall (`Dictation/DictationEngine.cs`, `TrayApp.cs`) |
| Edge-endpointing + preroll | yes | ported in `DictationEngine.cs` (300 ms preroll, VAD + ASR endpoint) |
| CJK de-spacing | drop spaces between CJK glyphs | `StreamingAsr.DeSpaceCjk` |
| Overlay | floating caption / oncall panel | borderless top-most `OverlayForm` (NOACTIVATE, click-through) |
| History | JSON | `%APPDATA%\VibeXASR\history.json` (`Storage/HistoryStore.cs`) |
| Settings | plist/JSON | `%APPDATA%\VibeXASR\settings.json` (`Storage/Settings.cs`) |
| Models | HF `GilgameshWind/X-ASR-zh-en` | same URL (`Models/ModelDownloader.cs`) |

## Source layout

```
windows_build/
├─ VibeXASR.Windows.sln
├─ build.ps1
├─ README.md
├─ .gitignore
└─ src/VibeXASR.Windows/
   ├─ VibeXASR.Windows.csproj      net8.0-windows, WinForms, win-x64;win-arm64, unsafe
   ├─ app.manifest                 DPI awareness + asInvoker
   ├─ Program.cs                   Main, [STAThread], single-instance, runs TrayApp
   ├─ TrayApp.cs                   tray menu; owns engine + hotkey + mic + overlay
   ├─ GlobalHotkey.cs              WH_KEYBOARD_LL push-to-talk hold (KeyDown/KeyUp)
   ├─ MicCapture.cs                NAudio WASAPI -> 16 kHz mono float frames
   ├─ Dictation/
   │  ├─ StreamingAsr.cs           sherpa OnlineRecognizer wrapper + CJK de-spacing
   │  ├─ Vad.cs                    sherpa VoiceActivityDetector wrapper
   │  └─ DictationEngine.cs        VAD->ASR orchestration, preroll, 3 modes, endpointing
   ├─ Input/
   │  └─ TextInserter.cs           SendInput KEYEVENTF_UNICODE + Backspace(n)
   ├─ Ui/                          macOS-faithful WinForms surfaces (port of VibeUI)
   │  ├─ Theme.cs                  design tokens (colors/fonts/radii) + dark title bar + rounded paths
   │  ├─ L10n.cs                   4-language zh/en/ja/ko string table (port of L10n.swift)
   │  ├─ Controls.cs               owner-drawn VibeToggle/VibeButton/Segmented/Select/ProgressBar + dark menu renderer
   │  ├─ Branding.cs               runtime-generated accent app/tray icon
   │  ├─ HotkeyRecorder.cs         click-to-record hotkey field (one-shot LL hook) + VK name map
   │  ├─ SettingsForm.cs           sidebar + General/Dictation/Model/Records/Permissions/About tabs
   │  ├─ TierManageRow.cs          per-tier download / use / cancel / delete row
   │  ├─ HistoryForm.cs            HistoryPanel (stats + privacy + list, copy/edit/delete) + standalone window
   │  ├─ TrayPopupForm.cs          menu-bar-style dropdown (status dot, recent card, toggle, entries)
   │  ├─ OverlayForm.cs            rounded HUD pill (orb + waveform + caret) + OnCall panel; click-through
   │  ├─ DownloadForm.cs           first-run model-download progress dialog
   │  └─ IAppController.cs         live seam between windows and TrayApp (the SettingsBridge analogue)
   ├─ Storage/
   │  ├─ Settings.cs               settings.json + enums + %APPDATA% paths (+ clip/history/launch/tray)
   │  └─ HistoryStore.cs           history.json: id/mode/expiry per entry, lifetime stats, 60s ephemeral
   └─ Models/
      ├─ ModelPaths.cs             resolve per-tier file paths
      ├─ ModelDownloader.cs        download a tier from HF with progress
      └─ ModelManager.cs           per-tier download state (progress/failed) + use/delete
```

## Resolved (vs. the original skeleton)

The original `// TODO(win):` items are done:

1. **sherpa-onnx C# API** — verified against `org.k2fsa.sherpa.onnx` **1.10.32**; the config
   struct/field names in `StreamingAsr.cs` / `Vad.cs` compile as-is.
2. **P/Invoke** — `SetWindowsHookEx`, `SendInput`, and the overlay now use the 64-bit
   `GetWindowLongPtr`/`SetWindowLongPtr` variants. A manifest typo (`manifest_version` →
   `manifestVersion`) that blocked process start was fixed.
3. **Real Settings + History windows** — full macOS-style Settings (6-tab sidebar, live
   tier/VAD/hotkey/language; switching tier/VAD re-downloads + rebuilds the engine) and a
   History window (stats, per-row copy/edit/delete, export, clear-all confirm).
4. **Tray UX** — a menu-bar-style rich popup (left-click) plus a dark-themed right-click menu.
5. **Overlay polish** — rounded gradient HUD pill (orb + reactive waveform + blinking caret),
   click-through HUD, interactive OnCall panel, and `CopyRequested` wired to the live text.
6. **4-language UI** (zh/en/ja/ko) ported from `L10n.swift`; **app/tray icon** generated at runtime.

> A hidden launch hook `VIBEXASR_OPEN=settings|history|popup|overlay[:oncall]` opens a single
> surface at startup (skips the engine) — handy for screenshots, and the seam for a future
> single-instance "show Settings".

## Building it here (notes)

The published artifacts are in [`dist/win-x64/`](dist/) and `dist/win-arm64/` (self-contained
single-file `VibeXASR.exe` + native `onnxruntime.dll` / `sherpa-onnx-c-api.dll`).

> **Per-user .NET SDK:** this machine had only .NET *runtimes*, no SDK. A machine-wide
> `winget` SDK install hangs on a UAC prompt in a non-interactive shell, so the SDK was
> installed per-user via `dotnet-install.ps1 -Channel 8.0 -InstallDir $env:USERPROFILE\.dotnet`
> (no admin). Build/publish with that `dotnet.exe` and `DOTNET_ROOT=$env:USERPROFILE\.dotnet`.
