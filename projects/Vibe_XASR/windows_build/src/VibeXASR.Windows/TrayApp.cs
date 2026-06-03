using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using VibeXASR.Windows.Dictation;
using VibeXASR.Windows.Input;
using System.Text.Json;
using VibeXASR.Windows.Lexicon;
using VibeXASR.Windows.Sharing;
using VibeXASR.Windows.Models;
using VibeXASR.Windows.Storage;
using VibeXASR.Windows.Ui;

namespace VibeXASR.Windows;

/// <summary>
/// Owns the whole runtime — tray icon + menu/popup, the dictation engine, the mic, the
/// global hotkey, the overlay, and the Settings/History windows. The Windows analogue of
/// the macOS AppDelegate / status-item controller. Implements <see cref="IAppController"/>
/// so every window writes its changes back here and they apply live.
/// </summary>
public sealed class TrayApp : IDisposable, IAppController
{
    public ApplicationContext Context { get; } = new();

    private readonly Settings _settings;
    private readonly HistoryStore _history = new();
    private LocalApiServer? _api;   // v1.4.0 本地共享 API
    private readonly PinyinNormalizer _pinyin = new();                                  // 词典: homophone correction
    private IReadOnlyList<Replacements.Rule> _replaceRules = Array.Empty<Replacements.Rule>(); // 词典: replacements
    private IReadOnlyList<Replacements.Rule> _snippetRules = Array.Empty<Replacements.Rule>(); // 口令: voice snippets
    private readonly ModelManager _models;

    private NotifyIcon? _tray;
    private GlobalHotkey? _hotkey;
    private MicCapture? _mic;
    private DictationEngine? _engine;
    private OverlayForm? _overlay;
    private TrayPopupForm? _popup;
    private SettingsForm? _settingsForm;
    private HistoryForm? _historyForm;
    private OnCallSessionForm? _onCallSessionForm;
    private OnboardingForm? _onboarding;
    private DownloadForm? _dl;

    // Ephemeral transcript of the CURRENT OnCall session (cleared when a session starts) —
    // distinct from the persistent _history store; this is what the overlay "View" button shows
    // (macOS OnCallLog parity). Mutated on the engine worker thread, read on the UI thread.
    private readonly List<HistoryEntry> _onCallSession = new();

    private SynchronizationContext _ui = null!;
    private string _typedSoFar = string.Empty;
    private volatile bool _engineReady;
    private volatile bool _engineSwapping;
    private bool _dictationEnabled = true;
    private volatile bool _listening;
    private volatile float _holdPeakRms;   // loudest mic level seen during the current hold (diagnostics)
    private bool _announcedReady;          // show the "ready" tray prompt once per launch

    public TrayApp()
    {
        _settings = Settings.Load();
        _models = new ModelManager(_settings);
        L10n.Current = L10n.FromCode(_settings.Language);
        Theme.IsDark = true; // dark-first like macOS; respect system below
        Theme.IsDark = DetectDark();
    }

    public void Start()
    {
        _ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();

        _overlay = new OverlayForm();
        _overlay.CopyRequested += (_, _) => CopyOverlayText();
        _overlay.StopRequested += (_, _) => SetMode(DictationMode.Paste); // leave OnCall
        _overlay.ViewRequested += (_, _) => OpenOnCallSession();
        _overlay.PauseRequested += (_, _) => TogglePause();
        // Realize the overlay handle so cross-thread BeginInvoke works immediately.
        _ = _overlay.Handle;

        _popup = new TrayPopupForm(this);

        BuildTray();
        RefreshCorrections();   // 词典: load homophone table + replacement rules
        CueSound.Shared.SetVolume(_settings.CueVolume);   // 提示音: sync cue volume from settings
        _api = new LocalApiServer(_settings, _history);   // 共享: local read-only HTTP API
        _api.Restart(_settings.ApiEnabled, _settings.ApiPort, _settings.ApiAllowLAN);

        _hotkey = new GlobalHotkey(_settings.HotkeyVk);
        _hotkey.KeyDown += (_, _) => OnHotkeyDown();
        _hotkey.KeyUp += (_, _) => OnHotkeyUp();
        _hotkey.Install();

        // Optional launch hook: VIBEXASR_OPEN=settings|history|popup opens that window at
        // startup (used for verification, and the seam for a future single-instance "show
        // settings"). In that mode we skip the engine bootstrap so no download dialog overlaps.
        var openRaw = Environment.GetEnvironmentVariable("VIBEXASR_OPEN")?.ToLowerInvariant();
        var open = openRaw?.Split(':')[0];
        var openArg = openRaw is not null && openRaw.Contains(':') ? openRaw.Split(':', 2)[1] : null;
        // Normal launch starts the engine; "popup"/"rebind" also do (they need real engine state).
        // settings/history/overlay hooks skip it for clean screenshots.
        if (string.IsNullOrEmpty(open) || open is "popup" or "rebind")
            _ = EnsureEngineAsync(swapping: false);
        // Auto-update (WinSparkle): start automatic daily checks on a normal launch only —
        // never during the screenshot/test hooks (settings/history/overlay/selftest…).
        if (string.IsNullOrEmpty(open))
            Updater.Initialize(_ui, Quit);
        // First launch ever: show the onboarding guide IMMEDIATELY (don't wait for the engine) —
        // the user needs to know the app is in the bottom-right tray and that the engine is still
        // preparing. The guide shows a live "preparing → ready" status.
        if (string.IsNullOrEmpty(open) && !_settings.Welcomed)
            ShowOnboarding();
        switch (open)
        {
            case "settings": OpenSettings(openArg); break;
            case "history": OpenHistory(); break;
            case "popup": _popup?.ShowNear(); break;
            case "rebind": SetHotkey(int.TryParse(openArg, out var vk) ? vk : 0x78); break; // live-rebind self-test
            case "selftest": _ = SelfTestAsync(openArg); break; // feed a WAV through the engine
            case "mictest": _ = MicTestAsync(); break; // capture real mic → save WAV → run ASR
            case "checkupdate": Updater.Initialize(_ui, Quit); Updater.CheckForUpdatesUi(); break; // WinSparkle UI
            case "onboard": ShowOnboarding(); break; // preview the first-run guide
            case "dicttest": RunDictTest(); break; // 词典 post-processor validation
            case "oncallsession": // populate a fake current-session log + open the session transcript view
                lock (_onCallSession)
                {
                    _onCallSession.Add(new HistoryEntry { Text = "把这个 function 改成 async。", Mode = "oncall", Timestamp = DateTimeOffset.Now.AddSeconds(-42) });
                    _onCallSession.Add(new HistoryEntry { Text = "顺便帮我加一个错误处理,别让它直接崩。", Mode = "oncall", Timestamp = DateTimeOffset.Now.AddSeconds(-18) });
                    _onCallSession.Add(new HistoryEntry { Text = "Then write a unit test for the parser.", Mode = "oncall", Timestamp = DateTimeOffset.Now });
                }
                OpenOnCallSession();
                break;
            case "overlay":
                _listening = true;
                _overlay?.ShowListening();
                _overlay?.SetLevel(0.7);
                _overlay?.SetText(openArg == "oncall" ? ""
                    : "把这个 function 改成 async,顺手把错误处理也补上,再写两句单元测试");
                if (openArg == "oncall") _overlay?.ShowOnCall();
                else if (openArg == "inserted") _overlay?.ShowInserted(autoHide: false);
                break;
        }
    }

    // ---- tray icon + menus ----

    private void BuildTray()
    {
        _tray = new NotifyIcon
        {
            Icon = Branding.AppIcon,
            Visible = _settings.ShowTrayIcon,
            Text = "Vibe XASR",
        };
        _tray.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left)
            {
                if (_popup is { Visible: true }) _popup.Hide();
                else _popup?.ShowNear();
            }
        };

        var menu = new ContextMenuStrip { Renderer = new DarkMenuRenderer(), Font = Theme.Ui(9.5f) };
        menu.BackColor = Theme.Surface2;
        menu.ForeColor = Theme.Text;
        menu.Opening += (_, _) => RebuildTrayMenu(menu);
        _tray.ContextMenuStrip = menu;
        RebuildTrayMenu(menu);
        UpdateTrayStatus();
    }

    private void RebuildTrayMenu(ContextMenuStrip menu)
    {
        menu.Items.Clear();

        var enable = new ToolStripMenuItem(L10n.T("menu.enable")) { Checked = _dictationEnabled, CheckOnClick = true };
        enable.Click += (_, _) => DictationEnabled = enable.Checked;
        menu.Items.Add(enable);

        menu.Items.Add(new ToolStripSeparator());

        var mode = new ToolStripMenuItem(L10n.T("dict.mode"));
        AddModeItem(mode, DictationMode.Paste, "dict.mode.paste.title");
        AddModeItem(mode, DictationMode.Type, "dict.mode.type.title");
        AddModeItem(mode, DictationMode.OnCall, "dict.mode.oncall.title");
        menu.Items.Add(mode);

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L10n.T("menu.history"), null, (_, _) => OpenHistory());
        menu.Items.Add(L10n.T("menu.settings"), null, (_, _) => OpenSettings());
        menu.Items.Add(L10n.Resolved == Lang.Zh ? "使用引导" : "Quick start guide", null, (_, _) => ShowOnboarding());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L10n.T("menu.quit"), null, (_, _) => Quit());
    }

    private void AddModeItem(ToolStripMenuItem parent, DictationMode m, string key)
    {
        var item = new ToolStripMenuItem(L10n.T(key)) { Checked = _settings.Mode == m, ForeColor = Theme.Text };
        item.Click += (_, _) => SetMode(m);
        parent.DropDownItems.Add(item);
    }

    // ---- model bootstrap / engine swap ----

    private async Task EnsureEngineAsync(bool swapping)
    {
        if (swapping) _engineSwapping = true;
        StopEngine();
        try
        {
            var paths = ModelPaths.ForTier(_settings.Tier);
            var vad = paths.ResolveVad(_settings.Vad);   // FireRed if bundled, else Silero
            Diag.Log($"EnsureEngine tier={(int)_settings.Tier} vad={vad} " +
                     $"asr={paths.AsrModelPresent()} vadPresent={paths.VadPresent(vad)}");
            if (!paths.AsrModelPresent() || !paths.VadPresent(vad))
            {
                ShowDownloadDialog();
                var dl = new ModelDownloader();
                var prog = new Progress<DownloadProgress>(p =>
                    _dl?.Report(p.Fraction ?? 0,
                        $"{p.FileName}  ({p.FileIndex + 1}/{p.FileCount})"));
                await dl.EnsureTierAsync(paths, prog);
                // Silero downloads on demand; FireRed ships bundled (ResolveVad already degraded to
                // Silero if FireRed was absent), so only Silero can need a fetch here.
                if (vad == VadKind.Silero) await dl.EnsureVadAsync(paths.VadFileFor(vad), prog);
                CloseDownloadDialog();
            }
            // Build the engine (565 MB model) OFF the UI thread so the app + hotkey stay
            // responsive, then start the mic ON the UI thread (WASAPI is more stable owned by a
            // pumping thread, and lets us hot-swap the device without a full reload).
            await Task.Run(BuildEngineCore);
            RunOnUi(() =>
            {
                StartMic();
                _engineReady = true;
                Diag.Log($"engine: READY (mic running={_mic?.IsRunning == true})");
                if (_settings.Mode == DictationMode.OnCall) EnterOnCall();
                _popup?.Invalidate();
                UpdateTrayStatus();
                AnnounceReady();
            });
        }
        catch (Exception ex)
        {
            CloseDownloadDialog();
            Diag.Log("ENGINE FAILED: " + ex);
            try { if (_tray is not null) _tray.Text = L10n.Resolved == Lang.Zh ? "Vibe XASR · 引擎加载失败" : "Vibe XASR · engine failed"; } catch { }
            _tray?.ShowBalloonTip(5000, "Vibe XASR",
                "Model/engine failed: " + ex.Message, ToolTipIcon.Error);
        }
        finally { _engineSwapping = false; }
    }

    /// <summary>Build the ASR/VAD engine + worker (heavy model load). Background thread. No mic.</summary>
    private void BuildEngineCore()
    {
        Diag.Log("engine: loading model…");
        _engine = new DictationEngine(_settings) { Mode = _settings.Mode };
        _engine.OnPartial += OnPartial;
        _engine.OnFinal += OnFinal;
        _engine.Start();
        Diag.Log("engine: model loaded");
    }

    /// <summary>(Re)start the microphone on the chosen device. Must run on the UI thread.</summary>
    private void StartMic()
    {
        if (_mic is not null) { _mic.FrameAvailable -= OnMicFrame; try { _mic.Dispose(); } catch { } _mic = null; }
        try
        {
            _mic = new MicCapture(_settings.MicDeviceId);
            _mic.FrameAvailable += OnMicFrame;
            _mic.Start();
        }
        catch (Exception ex) { Diag.Log("mic start failed: " + ex.Message); }
    }

    private void StopEngine()
    {
        _engineReady = false;
        if (_mic is not null) { _mic.FrameAvailable -= OnMicFrame; _mic.Dispose(); _mic = null; }
        if (_engine is not null)
        {
            _engine.OnPartial -= OnPartial;
            _engine.OnFinal -= OnFinal;
            _engine.Dispose();
            _engine = null;
        }
    }

    /// <summary>
    /// Diagnostic self-test: feed a speech WAV through the real engine as if it were a
    /// push-to-talk hold, and log the partials/final. Confirms the ASR pipeline produces
    /// text on Windows independent of the microphone. Triggered by VIBEXASR_OPEN=selftest:&lt;wav&gt;.
    /// </summary>
    private async Task SelfTestAsync(string? wavPath)
    {
        try
        {
            var paths = ModelPaths.ForTier(_settings.Tier);
            Diag.Log($"selftest: asrPresent={paths.AsrModelPresent()} wav={wavPath} exists={File.Exists(wavPath ?? "")}");
            if (!paths.AsrModelPresent() || string.IsNullOrEmpty(wavPath) || !File.Exists(wavPath)) return;

            // Read + downmix + resample to 16 kHz mono float via NAudio.
            var samples = new List<float>();
            using (var rdr = new AudioFileReader(wavPath))
            {
                ISampleProvider sp = rdr;
                if (sp.WaveFormat.Channels > 1) sp = sp.ToMono();
                if (sp.WaveFormat.SampleRate != 16000) sp = new WdlResamplingSampleProvider(sp, 16000);
                var buf = new float[16000];
                int n;
                while ((n = sp.Read(buf, 0, buf.Length)) > 0)
                    for (int i = 0; i < n; i++) samples.Add(buf[i]);
            }
            float peak = 0; foreach (var s in samples) peak = Math.Max(peak, Math.Abs(s));
            Diag.Log($"selftest: {samples.Count} samples ({samples.Count / 16000.0:F1}s) peak={peak:F3}");

            // Drive a fresh DictationEngine (its own model, NO mic) through the real PTT path:
            // BeginHold → push frames → EndHold. This exercises the exact code the hotkey uses
            // (queue + PTT branch + InputFinished + OnFinal), with one clean audio source.
            await Task.Run(() =>
            {
                using var eng = new DictationEngine(_settings) { Mode = DictationMode.Paste };
                eng.OnPartial += (_, ev) => { };
                eng.OnFinal += (_, ev) => Diag.Log($"selftest ENGINE OnFinal: len={ev.Text?.Length ?? 0} \"{ev.Text}\"");
                eng.Start();
                eng.BeginHold();
                for (int i = 0; i < samples.Count; i += 512)
                {
                    int n = Math.Min(512, samples.Count - i);
                    var f = new float[n];
                    samples.CopyTo(i, f, 0, n);
                    eng.PushFrame(f);
                    Thread.Sleep(8);
                }
                Thread.Sleep(400);
                eng.EndHold();
                Thread.Sleep(1500); // let the worker finalize
                Diag.Log("selftest: engine path done");
            });
        }
        catch (Exception ex) { Diag.Log("selftest FAILED: " + ex); }
    }

    /// <summary>Once per launch, tell the user the app is live + how to use it (tray prompt),
    /// since otherwise it just sits silently in the notification area.</summary>
    private void AnnounceReady()
    {
        if (_announcedReady || _tray is null) return;
        _announcedReady = true;

        // First launch: the onboarding window is already open (shown in Start) and flips its own
        // status to "ready", so don't also fire a balloon. Once the user has been through the
        // guide (Welcomed == true), a lightweight tray prompt with the hotkey hint is enough.
        if (!_settings.Welcomed) return;

        var key = VkNames.Name(_settings.HotkeyVk);
        bool zh = L10n.Resolved == Lang.Zh;
        string title = zh ? "Vibe XASR 已就绪" : "Vibe XASR is ready";
        string msg = _settings.Mode == DictationMode.OnCall
            ? (zh ? "持续候机已开启 · 识别结果显示在右上角悬浮窗" : "OnCall is on · live text shows top-right")
            : (zh ? $"按住 {key} 说话,松开即把文字落到光标处。" : $"Hold {key} and speak; release to drop the text.");
        try { _tray.ShowBalloonTip(6000, title, msg, ToolTipIcon.Info); } catch { }
    }

    /// <summary>Show the first-run onboarding guide (also re-runnable from the tray menu).</summary>
    private void ShowOnboarding()
    {
        RunOnUi(() =>
        {
            try
            {
                if (_onboarding is { IsDisposed: false }) { _onboarding.Activate(); _onboarding.BringToFront(); return; }
                _onboarding = new OnboardingForm(this);
                _onboarding.FormClosed += (_, _) => _onboarding = null;
                _onboarding.Show();
            }
            catch (Exception ex) { Diag.Log("onboarding failed: " + ex); }
        });
    }

    /// <summary>Reflect engine state in the tray tooltip (the Windows analog of the macOS
    /// status-bar text): preparing → ready / OnCall. Surfaces the slower-than-macOS model load so
    /// the tray isn't silent while the user waits.</summary>
    private void UpdateTrayStatus()
    {
        if (_tray is null) return;
        bool zh = L10n.Resolved == Lang.Zh;
        string s;
        if (!_engineReady)
            s = zh ? "Vibe XASR · 正在准备识别引擎…" : "Vibe XASR · preparing engine…";
        else if (_settings.Mode == DictationMode.OnCall)
            s = zh ? "Vibe XASR · 持续候机中" : "Vibe XASR · OnCall active";
        else
            s = zh ? $"Vibe XASR · 就绪,按住 {VkNames.Name(_settings.HotkeyVk)} 说话"
                   : $"Vibe XASR · ready — hold {VkNames.Name(_settings.HotkeyVk)}";
        if (s.Length > 63) s = s.Substring(0, 63);
        try { _tray.Text = s; } catch { }
    }

    /// <summary>
    /// Mic diagnostic: capture ~6 s from the real microphone, log device/format/level, save it
    /// to %APPDATA%\VibeXASR\mictest.wav, and run the ASR on it — so we can see whether the
    /// user's mic audio actually reaches + recognizes. Triggered by VIBEXASR_OPEN=mictest.
    /// </summary>
    // Runs entirely on a background thread (synchronous) so it can't stall on the startup
    // sync-context. Captures the real mic for 6 s, logs level, saves a WAV, and runs the ASR.
    private Task MicTestAsync() => Task.Run(() =>
    {
        try
        {
            var samples = new List<float>();
            int frames = 0; float peak = 0;
            var mic = new MicCapture();
            mic.FrameAvailable += (_, f) =>
            {
                frames++;
                lock (samples) samples.AddRange(f);
                double s = 0; foreach (var v in f) s += v * v;
                float rms = f.Length > 0 ? (float)Math.Sqrt(s / f.Length) : 0;
                if (rms > peak) peak = rms;
            };
            mic.Start();
            RunOnUi(() => _tray?.ShowBalloonTip(6500, "Vibe XASR",
                L10n.Resolved == Lang.Zh ? "麦克风测试:请现在说话 6 秒…" : "Mic test: please speak for 6 seconds…",
                ToolTipIcon.Info));
            Diag.Log("mictest: recording 6s — SPEAK NOW");
            Thread.Sleep(6000);

            float[] arr; lock (samples) arr = samples.ToArray();
            Diag.Log($"mictest: frames={frames} samples={arr.Length} ({arr.Length / 16000.0:F1}s) peakRMS={peak:F4}");
            try { mic.Stop(); mic.Dispose(); } catch (Exception ex) { Diag.Log("mic stop/dispose: " + ex.Message); }

            var wav = System.IO.Path.Combine(AppPaths.DataDir, "mictest.wav");
            using (var w = new WaveFileWriter(wav, WaveFormat.CreateIeeeFloatWaveFormat(16000, 1)))
                w.WriteSamples(arr, 0, arr.Length);
            Diag.Log("mictest: saved " + wav);

            using var asr = new StreamingAsr(ModelPaths.ForTier(_settings.Tier), 16000);
            for (int i = 0; i < arr.Length; i += 1600)
            {
                int n = Math.Min(1600, arr.Length - i);
                var f = new float[n]; Array.Copy(arr, i, f, 0, n);
                asr.AcceptWaveform(f);
            }
            var text = asr.Finalize();
            Diag.Log($"mictest ASR result: \"{text}\"");
            RunOnUi(() => _tray?.ShowBalloonTip(8000, "Vibe XASR",
                string.IsNullOrEmpty(text)
                    ? (L10n.Resolved == Lang.Zh ? $"未识别到内容(峰值音量 {peak:F3})" : $"Nothing recognized (peak {peak:F3})")
                    : (L10n.Resolved == Lang.Zh ? "识别到:" : "Recognized: ") + text,
                ToolTipIcon.Info));
        }
        catch (Exception ex) { Diag.Log("mictest FAILED: " + ex); }
    });

    private void ShowDownloadDialog()
        => RunOnUi(() => { _dl ??= new DownloadForm(); if (!_dl.Visible) _dl.Show(); });

    private void CloseDownloadDialog()
        => RunOnUi(() => { _dl?.Hide(); });

    // ---- mic → engine + level meter ----

    private void OnMicFrame(object? sender, float[] frame)
    {
        _engine?.PushFrame(frame);
        // Cheap RMS envelope to drive the overlay waveform.
        double sum = 0;
        for (int i = 0; i < frame.Length; i++) sum += frame[i] * frame[i];
        double rms = frame.Length > 0 ? Math.Sqrt(sum / frame.Length) : 0;
        if (rms > _holdPeakRms) _holdPeakRms = (float)rms;
        _overlay?.SetLevel(Math.Min(1.0, rms * 6.0));
    }

    // ---- hotkey ----

    private void OnHotkeyDown()
    {
        Diag.Log($"OnHotkeyDown enabled={_dictationEnabled} mode={_settings.Mode} ready={_engineReady}");
        if (!_dictationEnabled)
        {
            _tray?.ShowBalloonTip(2500, "Vibe XASR",
                L10n.Resolved == Lang.Zh ? "听写已停用(在菜单里启用)" : "Dictation is disabled (enable it in the menu).",
                ToolTipIcon.Info);
            return;
        }
        if (_settings.Mode == DictationMode.OnCall) return; // OnCall is always-on; PTT n/a
        if (!_engineReady)
        {
            // Don't fail silently — tell the user the model is still loading.
            _tray?.ShowBalloonTip(2500, "Vibe XASR",
                L10n.Resolved == Lang.Zh ? "模型正在加载,请稍候…" : "Model is still loading, please wait…",
                ToolTipIcon.Info);
            return;
        }
        _typedSoFar = string.Empty;
        _holdPeakRms = 0;
        _listening = true;
        _engine?.BeginHold();
        _overlay?.ShowListening();
        if (_settings.CueEnabled) CueSound.Shared.Play(_settings.CueTheme, start: true);   // 提示音: start chime
    }

    private void OnHotkeyUp()
    {
        if (_settings.Mode == DictationMode.OnCall) return;
        if (!_listening) return;
        _listening = false;
        Diag.Log($"OnHotkeyUp; peak mic RMS={_holdPeakRms:F4}");
        _engine?.EndHold();
        if (_settings.CueEnabled) CueSound.Shared.Play(_settings.CueTheme, start: false);  // 提示音: stop chime
    }

    // ---- engine events (raised on the engine worker thread) ----

    private void OnPartial(object? sender, PartialEventArgs e)
    {
        switch (_settings.Mode)
        {
            case DictationMode.Paste:
            case DictationMode.OnCall:
                _overlay?.SetText(e.Text);
                break;
            case DictationMode.Type:
                StreamTypeDiff(e.Text);
                _overlay?.SetText(e.Text);
                break;
        }
        if (_popup is { Visible: true }) RunOnUi(() => _popup?.Invalidate());
    }

    private void OnFinal(object? sender, FinalEventArgs e)
    {
        Diag.Log($"OnFinal mode={_settings.Mode} len={e.Text?.Length ?? 0} text=\"{Trunc(e.Text)}\"");

        // Empty final = end-of-hold with nothing recognized: just close the overlay (PTT),
        // don't insert/record. (Without this the overlay would stay up after release.)
        if (string.IsNullOrEmpty(e.Text))
        {
            if (_settings.Mode != DictationMode.OnCall) _overlay?.HideOverlay();
            return;
        }

        // 词典 post-processing: homophone (pinyin) correction → text replacements, before insert.
        var text = ApplyCorrections(e.Text);

        var modeTag = _settings.Mode.ToString().ToLowerInvariant();
        _history.Append(text, modeTag, ephemeral: !_settings.HistoryEnabled);

        switch (_settings.Mode)
        {
            case DictationMode.Paste:
                TextInserter.InsertText(text);
                MaybeOverwriteClipboard(text);
                _overlay?.SetText(text);     // so the "已插入 · N 字" count reflects the inserted text
                _overlay?.ShowInserted();
                break;
            case DictationMode.Type:
                StreamTypeDiff(text);
                _typedSoFar = string.Empty;
                MaybeOverwriteClipboard(text);
                _overlay?.SetText(text);
                _overlay?.ShowInserted();
                break;
            case DictationMode.OnCall:
                lock (_onCallSession)
                    _onCallSession.Add(new HistoryEntry { Text = text.Trim(), Mode = "oncall", Timestamp = DateTimeOffset.Now });
                RefreshOnCallSession();
                _overlay?.SetText(text);
                break;
        }
        RefreshOpenWindows();
    }

    /// <summary>Apply the post-processors to a final result, matching the macOS pipeline order:
    /// pinyin homophone correction → text replacements → 去口水词 → 数字规整 (ITN) → 口令 expansion.
    /// Each step no-ops unless enabled + populated. Runs on FINAL text only (not streaming partials,
    /// where ITN digits would jump as you speak).</summary>
    private string ApplyCorrections(string textIn)
    {
        var text = textIn;
        if (_settings.PinyinFuzzyEnabled && _pinyin.IsActive) text = _pinyin.Normalize(text);
        if (_settings.ReplacementsEnabled && _replaceRules.Count > 0) text = Replacements.Apply(text, _replaceRules);
        if (_settings.DefillerEnabled) text = Defiller.Clean(text);                 // 去口水词: strip fillers first
        if (_settings.ItnEnabled) text = ChineseITN.Normalize(text);                // 数字规整: then normalize numbers
        if (_settings.SnippetsEnabled && _snippetRules.Count > 0) text = Replacements.Expand(text, _snippetRules); // 口令: expand last
        return text;
    }

    /// <summary>(Re)load the homophone table + dictionary words + replacement rules from settings.
    /// Called on launch and whenever the 词典 settings change (no engine rebuild needed for these).</summary>
    private void RefreshCorrections()
    {
        try
        {
            _pinyin.LoadTableIfNeeded(ModelPaths.ForTier(_settings.Tier).PinyinTable);
            _pinyin.SetWords(_settings.PinyinFuzzyEnabled ? HotwordsStore.Normalize(_settings.HotwordsText) : new List<string>());
            _replaceRules = _settings.ReplacementsEnabled ? Replacements.Parse(_settings.ReplacementsText) : Array.Empty<Replacements.Rule>();
            _snippetRules = _settings.SnippetsEnabled ? ParseSnippets(_settings.SnippetsJson) : Array.Empty<Replacements.Rule>();
            Diag.Log($"corrections: pinyin={_pinyin.IsActive} rules={_replaceRules.Count} snippets={_snippetRules.Count} itn={_settings.ItnEnabled} defiller={_settings.DefillerEnabled}");
        }
        catch (Exception ex) { Diag.Log("RefreshCorrections failed: " + ex.Message); }
    }

    /// <summary>Parse snippets JSON (<c>[{"t":trigger,"x":text}]</c>) into expansion rules.</summary>
    private static IReadOnlyList<Replacements.Rule> ParseSnippets(string? json)
    {
        var rules = new List<Replacements.Rule>();
        if (string.IsNullOrWhiteSpace(json)) return rules;
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return rules;
            foreach (var el in doc.RootElement.EnumerateArray())
            {
                if (el.ValueKind != JsonValueKind.Object) continue;
                var t = el.TryGetProperty("t", out var tv) ? tv.GetString() : null;
                var x = el.TryGetProperty("x", out var xv) ? xv.GetString() : null;
                if (!string.IsNullOrEmpty(t)) rules.Add(new Replacements.Rule(t, x ?? ""));
            }
        }
        catch (Exception ex) { Diag.Log("ParseSnippets failed: " + ex.Message); }
        return rules;
    }

    /// <summary>Hidden 词典 self-test (VIBEXASR_OPEN=dicttest): exercises the hotwords-file writer,
    /// the pinyin homophone normalizer, and the replacement engine on sample text → log.txt.</summary>
    private void RunDictTest()
    {
        var paths = ModelPaths.ForTier(_settings.Tier);
        try
        {
            HotwordsStore.WriteFile("贾扬清\n沈向洋\nOpenAI\nPyTorch", 5.0, paths.HotwordsFile);
            Diag.Log("dicttest hotwords.txt:\n" + (File.Exists(paths.HotwordsFile) ? File.ReadAllText(paths.HotwordsFile) : "(none)"));

            var pn = new PinyinNormalizer();
            pn.LoadTableIfNeeded(paths.PinyinTable);
            pn.SetWords(new[] { "贾扬清", "沈向洋" });
            Diag.Log($"dicttest pinyin active={pn.IsActive}");
            foreach (var t in new[] { "贾阳清", "嘉阳青", "沈向阳", "你好世界" })
                Diag.Log($"  pinyin '{t}' -> '{pn.Normalize(t)}'");

            var rules = Replacements.Parse("open claw => OpenClaw\n李牧 => 李沐");
            foreach (var t in new[] { "我用 open claw 框架", "李牧老师", "OPEN CLAW yes" })
                Diag.Log($"  replace '{t}' -> '{Replacements.Apply(t, rules)}'");

            // 数字规整 (ITN)
            foreach (var t in new[] { "一百二十三", "二零二四年", "三点半", "百分之二十五", "五千八百块",
                                      "端口八零八零", "下午三点一刻", "第一个人", "等一下", "一带一路" })
                Diag.Log($"  itn '{t}' -> '{ChineseITN.Normalize(t)}'");

            // 去口水词 (defiller)
            foreach (var t in new[] { "嗯这个就是就是我的想法", "那个那个我们看看", "呃我我我觉得", "好好学习" })
                Diag.Log($"  defiller '{t}' -> '{Defiller.Clean(t)}'");

            // 口令 (snippets): trigger tolerates spaced letters + eats one trailing sentence mark
            var snips = ParseSnippets("[{\"t\":\"我的邮箱\",\"x\":\"tao@example.com\"},{\"t\":\"cc\",\"x\":\"抄送\"}]");
            foreach (var t in new[] { "请发到我的邮箱。", "麻烦 C C 一下", "我的邮箱" })
                Diag.Log($"  snippet '{t}' -> '{Replacements.Expand(t, snips)}'");

            // 提示音 (cue) — verify synthesis + playback path doesn't throw (covers sine + FM timbres)
            CueSound.Shared.SetVolume("med");
            CueSound.Shared.Play("chime", start: true);
            CueSound.Shared.Play("marimba", start: false);
            Diag.Log("  cue: chime/marimba rendered + played ok");
            Diag.Log("dicttest done");
        }
        catch (Exception ex) { Diag.Log("dicttest error: " + ex); }
    }

    private void MaybeOverwriteClipboard(string text)
    {
        if (!_settings.ClipboardOverwrite || string.IsNullOrEmpty(text)) return;
        RunOnUi(() => { try { Clipboard.SetText(text); } catch { } });
    }

    /// <summary>Type-mode incremental insertion: keep the common prefix, backspace the
    /// divergent tail, type the new suffix (mirrors the macOS streaming inserter).</summary>
    private void StreamTypeDiff(string newText)
    {
        int common = 0, max = Math.Min(_typedSoFar.Length, newText.Length);
        while (common < max && _typedSoFar[common] == newText[common]) common++;
        int toDelete = _typedSoFar.Length - common;
        if (toDelete > 0) TextInserter.Backspace(toDelete);
        var suffix = newText[common..];
        if (suffix.Length > 0) TextInserter.InsertText(suffix);
        _typedSoFar = newText;
    }

    // ---- IAppController ----

    public Settings Settings => _settings;
    public HistoryStore History => _history;
    public ModelManager Models => _models;
    public bool EngineSwapping => _engineSwapping;
    public bool EngineReady => _engineReady;
    public bool IsListening => _listening || _settings.Mode == DictationMode.OnCall;
    public string CurrentOverlayText => _overlay?.CurrentText ?? string.Empty;

    public bool DictationEnabled
    {
        get => _dictationEnabled;
        set
        {
            _dictationEnabled = value;
            if (!value && _settings.Mode == DictationMode.OnCall) SetMode(DictationMode.Paste);
            _popup?.Invalidate();
        }
    }

    public void SetMode(DictationMode mode)
    {
        if (_settings.Mode == mode) return;
        bool wasOnCall = _settings.Mode == DictationMode.OnCall;
        _settings.Mode = mode;
        _settings.Save();
        if (_engine is not null) _engine.Mode = mode;

        if (wasOnCall && mode != DictationMode.OnCall) _overlay?.LeaveOnCall();
        if (mode == DictationMode.OnCall) EnterOnCall();

        NotifyExternallyChanged();
    }

    private void EnterOnCall()
    {
        if (_engine is not null) _engine.Mode = DictationMode.OnCall;
        lock (_onCallSession) _onCallSession.Clear();   // fresh session log (macOS clears on start)
        RefreshOnCallSession();
        _overlay?.ShowOnCall();
        _overlay?.SetText(string.Empty);
    }

    private void TogglePause()
    {
        if (_engine is not null) _engine.Paused = !_engine.Paused;
    }

    public void SetVad(VadKind vad)
    {
        if (_settings.Vad == vad) return;
        _settings.Vad = vad; _settings.Save();
        _ = EnsureEngineAsync(swapping: true);
    }

    public void SelectTier(ModelTier tier)
    {
        if (_settings.Tier == tier && _engineReady) return;
        _settings.Tier = tier; _settings.Save();
        _ = EnsureEngineAsync(swapping: true);
    }

    public void SetHotkey(int vk)
    {
        _settings.HotkeyVk = vk; _settings.Save();
        _hotkey?.SetKey(vk);
    }

    public void SetLanguage(Lang lang)
    {
        L10n.Current = lang;
        _settings.Language = L10n.ToCode(lang);
        _settings.Save();
        _popup?.Invalidate();
    }

    public void SetClipboardOverwrite(bool on) { _settings.ClipboardOverwrite = on; _settings.Save(); }
    public void SetHistoryEnabled(bool on) { _settings.HistoryEnabled = on; _settings.Save(); }

    // ---- 词典 (dictionary) ----
    public void SetHotwords(bool enabled, string text, double score)
    {
        _settings.HotwordsEnabled = enabled;
        _settings.HotwordsText = text ?? "";
        _settings.HotwordsScore = score;
        _settings.Save();
        RefreshCorrections();                  // pinyin words are derived from the hotwords list
        _ = EnsureEngineAsync(swapping: true);  // rebuild so sherpa picks up the new biasing
    }

    public void SetReplacements(bool enabled, string text)
    {
        _settings.ReplacementsEnabled = enabled;
        _settings.ReplacementsText = text ?? "";
        _settings.Save();
        RefreshCorrections();                   // live; no engine rebuild
    }

    public void SetPinyinFuzzy(bool on)
    {
        _settings.PinyinFuzzyEnabled = on;
        _settings.Save();
        RefreshCorrections();                   // live; no engine rebuild
    }

    public void SetItn(bool on)
    {
        _settings.ItnEnabled = on;
        _settings.Save();                       // live; read directly in ApplyCorrections
    }

    public void SetDefiller(bool on)
    {
        _settings.DefillerEnabled = on;
        _settings.Save();                       // live
    }

    public void SetSnippets(bool enabled, string json)
    {
        _settings.SnippetsEnabled = enabled;
        _settings.SnippetsJson = json ?? "[]";
        _settings.Save();
        RefreshCorrections();                   // re-parse 口令 rules; no engine rebuild
    }

    // ---- 提示音 (cue sound) — changes preview the sound so the user hears them ----
    public void SetCueEnabled(bool on)
    {
        _settings.CueEnabled = on;
        _settings.Save();
        if (on) CueSound.Shared.Play(_settings.CueTheme, start: true);
    }

    public void SetCueTheme(string theme)
    {
        _settings.CueTheme = string.IsNullOrEmpty(theme) ? "chime" : theme;
        _settings.Save();
        if (_settings.CueEnabled) CueSound.Shared.Play(_settings.CueTheme, start: true);
    }

    public void SetCueVolume(string preset)
    {
        _settings.CueVolume = string.IsNullOrEmpty(preset) ? "low" : preset;
        _settings.Save();
        CueSound.Shared.SetVolume(_settings.CueVolume);
        if (_settings.CueEnabled) CueSound.Shared.Play(_settings.CueTheme, start: true);
    }

    // ---- 共享 (local share API) ----
    public bool ApiRunning => _api?.IsRunning ?? false;
    public int ApiBoundPort => _api?.BoundPort ?? 0;
    public string ApiKey => _settings.ApiKey;

    public void SetApiEnabled(bool on)
    {
        _settings.ApiEnabled = on; _settings.Save();
        _api?.Restart(on, _settings.ApiPort, _settings.ApiAllowLAN);
    }
    public void SetApiAllowLAN(bool on)
    {
        _settings.ApiAllowLAN = on; _settings.Save();
        _api?.Restart(_settings.ApiEnabled, _settings.ApiPort, on);
    }
    public void SetApiPort(int port)
    {
        _settings.ApiPort = port; _settings.Save();
        _api?.Restart(_settings.ApiEnabled, port, _settings.ApiAllowLAN);
    }
    public string RegenerateApiKey()
    {
        var k = _settings.RegenerateApiKey();
        _api?.Restart(_settings.ApiEnabled, _settings.ApiPort, _settings.ApiAllowLAN);   // pick up the new key
        return k;
    }

    public void SetLaunchAtLogin(bool on)
    {
        _settings.LaunchAtLogin = on; _settings.Save();
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Run", writable: true);
            if (key is null) return;
            if (on) key.SetValue("VibeXASR", $"\"{Application.ExecutablePath}\"");
            else key.DeleteValue("VibeXASR", throwOnMissingValue: false);
        }
        catch { /* registry locked — non-fatal */ }
    }

    public bool MicGranted()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone");
            // "Deny" => blocked globally. Missing/"Allow" => permitted.
            return key?.GetValue("Value") as string != "Deny";
        }
        catch { return true; }
    }

    public void OpenMicPrivacy()
    {
        try { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); }
        catch { }
    }

    public System.Collections.Generic.List<(string Id, string Name)> MicDevices() => MicCapture.Devices();
    public string MicDeviceId => _settings.MicDeviceId;

    public void SetMicDevice(string id)
    {
        if (_settings.MicDeviceId == id) return;
        _settings.MicDeviceId = id;
        _settings.Save();
        Diag.Log($"SetMicDevice -> {id}");
        if (_engineReady) RunOnUi(StartMic); // hot-swap the mic only (no model reload)
    }

    public void OpenSettings() => OpenSettings(null);

    private void OpenSettings(string? tab)
    {
        RunOnUi(() =>
        {
            if (_settingsForm is { IsDisposed: false })
            {
                _settingsForm.Activate();
                if (tab is not null) _settingsForm.ShowTab(tab);
                return;
            }
            _settingsForm = new SettingsForm(this) { Icon = Branding.AppIcon };
            if (tab is not null) _settingsForm.ShowTab(tab);
            _settingsForm.Show();
            _settingsForm.Activate();
            _settingsForm.BringToFront();
        });
    }

    public void OpenHistory()
    {
        RunOnUi(() =>
        {
            if (_historyForm is { IsDisposed: false }) { _historyForm.Activate(); _historyForm.BringToFront(); return; }
            _historyForm = new HistoryForm(_history) { Icon = Branding.AppIcon };
            _historyForm.Show();
            _historyForm.Activate();
            _historyForm.BringToFront();
        });
    }

    /// <summary>Open the CURRENT OnCall session transcript (the overlay "View" button) — the
    /// ephemeral per-session records, NOT the global history (macOS OnCallSessionView parity).</summary>
    public void OpenOnCallSession()
    {
        RunOnUi(() =>
        {
            if (_onCallSessionForm is { IsDisposed: false })
            { _onCallSessionForm.Reload(); _onCallSessionForm.Activate(); _onCallSessionForm.BringToFront(); return; }
            _onCallSessionForm = new OnCallSessionForm(SnapshotOnCallSession) { Icon = Branding.AppIcon };
            _onCallSessionForm.Show();
            _onCallSessionForm.Activate();
            _onCallSessionForm.BringToFront();
        });
    }

    private IReadOnlyList<HistoryEntry> SnapshotOnCallSession()
    {
        lock (_onCallSession) return _onCallSession.ToList();
    }

    private void RefreshOnCallSession()
    {
        if (_onCallSessionForm is { IsDisposed: false }) RunOnUi(() => _onCallSessionForm?.Reload());
    }

    private string OnCallSessionText()
    {
        lock (_onCallSession)
            return string.Join(Environment.NewLine,
                _onCallSession.Select(e => $"[{e.Timestamp.LocalDateTime:yyyy-MM-dd HH:mm:ss}] {e.Text}"));
    }

    public void Quit()
    {
        Dispose();
        Application.ExitThread();
    }

    // ---- helpers ----

    private void CopyOverlayText()
    {
        // OnCall: copy the WHOLE current session (timestamped), like macOS. PTT: copy the current
        // overlay text, falling back to the most recent history entry.
        string? text;
        if (_settings.Mode == DictationMode.OnCall)
            text = OnCallSessionText();
        else
        {
            text = _overlay?.CurrentText;
            if (string.IsNullOrEmpty(text)) text = _history.List().FirstOrDefault()?.Text;
        }
        if (!string.IsNullOrEmpty(text))
            RunOnUi(() => { try { Clipboard.SetText(text!); } catch { } });
    }

    private void RefreshOpenWindows()
    {
        if (_popup is { Visible: true }) RunOnUi(() => _popup?.Invalidate());
    }

    private void NotifyExternallyChanged()
    {
        // Keep an open Settings window's controls in sync after a programmatic change.
        RunOnUi(() =>
        {
            _popup?.Invalidate();
            UpdateTrayStatus();
            if (_tray?.ContextMenuStrip is { } m) RebuildTrayMenu(m);
        });
    }

    private void RunOnUi(Action action)
    {
        if (_ui is not null) _ui.Post(_ => action(), null);
        else action();
    }

    private static string Trunc(string? s, int n = 40)
        => string.IsNullOrEmpty(s) ? "" : (s.Length <= n ? s : s[..n] + "…");

    private static bool DetectDark()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            if (key?.GetValue("AppsUseLightTheme") is int v) return v == 0;
        }
        catch { }
        return true;
    }

    public void Dispose()
    {
        Updater.Cleanup();
        _hotkey?.Dispose(); _hotkey = null;
        StopEngine();
        _overlay?.Dispose(); _overlay = null;
        _popup?.Dispose(); _popup = null;
        _dl?.Dispose(); _dl = null;
        if (_tray is not null) { _tray.Visible = false; _tray.Dispose(); _tray = null; }
    }
}
