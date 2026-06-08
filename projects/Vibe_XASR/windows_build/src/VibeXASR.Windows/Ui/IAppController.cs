using VibeXASR.Windows.Models;
using VibeXASR.Windows.Storage;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// The seam between the windows (Settings / History / tray popup) and the running app
/// (<c>TrayApp</c>). Every live control reads/writes through here so a change applies
/// immediately (re-download a tier, rebuild the engine, rebind the hotkey, …). This is
/// the Windows analogue of the macOS <c>SettingsBridge</c>.
/// </summary>
public interface IAppController
{
    Settings Settings { get; }
    HistoryStore History { get; }
    ModelManager Models { get; }

    /// <summary>True while the engine is rebuilding after a VAD/tier change (UI shows "switching…").</summary>
    bool EngineSwapping { get; }

    // ----- live setters (apply + persist) -----
    void SetMode(DictationMode mode);
    void SetVad(VadKind vad);
    void SelectTier(ModelTier tier);
    void SetModelSource(string code);   // "official" | "modelscope" | "huggingface" — download mirror
    void SetHotkey(int vk, int mods);   // vk + modifier bitfield (Ctrl=1,Alt=2,Shift=4,Win=8)
    void SetLanguage(Lang lang);
    void SetClipboardOverwrite(bool on);
    void SetHistoryEnabled(bool on);
    void SetLaunchAtLogin(bool on);

    // ----- macOS build 204 parity -----
    void SetHudStay(double seconds);          // E: overlay bar stay duration after each utterance
    void SetOutputTraditional(bool on);       // C: convert inserted text to 繁体 (simplified→traditional)
    void SetTrigger(TriggerMode mode);        // A: hold-to-talk / tap-to-latch / pure toggle
    void SetMicMuted(bool on);                // G: tray quick mic-mute (drops capture)
    void SetActiveTemplate(string id);        // G/B: switch the active AI-polish prompt template

    // ----- desktop floating launcher (find/open the app) -----
    void SetLauncherEnabled(bool on);                       // 通用 toggle: show/hide the launcher pill
    void ShowQuickMenu(double screenX, double screenY);     // launcher click → tray popup near that point

    // ----- 词典 (dictionary): hotword bias + pinyin homophone correction + replacements -----
    void SetHotwords(bool enabled, string text, double score);
    void SetReplacements(bool enabled, string text);
    void SetPinyinFuzzy(bool on);

    // ----- v1.3.0 final-text post-processors -----
    void SetItn(bool on);            // 数字规整 (ITN)
    void SetDefiller(bool on);       // 去口水词
    void SetSnippets(bool enabled, string json);   // 口令 (voice snippets)

    // ----- cue sound (subtle chime on dictation start/stop) -----
    void SetCueEnabled(bool on);
    void SetCueTheme(string theme);      // tick | chime | soft | drop | marimba
    void SetCueVolume(string preset);    // low | med | high

    // ----- v1.4.0 local share API (共享) -----
    bool ApiRunning { get; }
    int ApiBoundPort { get; }
    string ApiKey { get; }
    void SetApiEnabled(bool on);
    void SetApiAllowLAN(bool on);
    void SetApiPort(int port);
    string RegenerateApiKey();

    // ----- AI 润色 (cloud LLM refinement) -----
    void ApplyCloudSettings();   // persist 润色 settings + reconfigure the refiner backend

    // ----- permissions (Windows: microphone privacy) -----
    bool MicGranted();
    void OpenMicPrivacy();

    // ----- microphone device selection -----
    System.Collections.Generic.List<(string Id, string Name)> MicDevices();
    string MicDeviceId { get; }
    void SetMicDevice(string id);

    // ----- OnCall overlay live text (for the tray popup "recent" + copy) -----
    string CurrentOverlayText { get; }

    /// <summary>Master enable for dictation (the tray popup toggle). Off ignores the hotkey.</summary>
    bool DictationEnabled { get; set; }

    /// <summary>True while actively capturing (push-to-talk held or OnCall live).</summary>
    bool IsListening { get; }

    /// <summary>True once the model is loaded and the engine is running.</summary>
    bool EngineReady { get; }

    // ----- window actions (tray popup / menu) -----
    void OpenSettings();
    void OpenHistory();
    void OpenPromptStudio();   // 提示词工作室 (Prompt Template Studio)
    void Quit();
}
