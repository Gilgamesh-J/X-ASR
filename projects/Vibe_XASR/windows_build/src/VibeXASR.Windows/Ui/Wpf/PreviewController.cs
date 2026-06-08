using System;
using System.Collections.Generic;
using VibeXASR.Windows.Models;
using VibeXASR.Windows.Storage;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>A no-engine <see cref="IAppController"/> for the WPF design preview: it reflects setter
/// changes in an in-memory Settings (no save, no engine) so the redesigned windows can be exercised /
/// screenshotted standalone. Not used in the shipping app.</summary>
internal sealed class PreviewController : IAppController
{
    public Settings Settings { get; } = PreviewSettings();
    private static Settings PreviewSettings() { var s = Settings.Load(); if (Environment.GetEnvironmentVariable("VIBEXASR_PREVIEW_SHARE") == "1") s.ApiEnabled = true; return s; }
    public HistoryStore History { get; } = new HistoryStore();
    public ModelManager Models { get; }
    public PreviewController() => Models = new ModelManager(Settings);
    public bool EngineSwapping => false;

    public void SetMode(DictationMode mode) => Settings.Mode = mode;
    public void SetVad(VadKind vad) { }
    public void SelectTier(ModelTier tier) => Settings.Tier = tier;
    public void SetModelSource(string code) => Settings.ModelSource = code;
    public void SetHotkey(int vk, int mods) { Settings.HotkeyVk = vk; Settings.HotkeyMods = mods; }
    public void SetLanguage(Lang lang) { Settings.Language = L10n.ToCode(lang); L10n.Current = lang; }
    public void SetClipboardOverwrite(bool on) => Settings.ClipboardOverwrite = on;
    public void SetHistoryEnabled(bool on) => Settings.HistoryEnabled = on;
    public void SetLaunchAtLogin(bool on) => Settings.LaunchAtLogin = on;
    public void SetHudStay(double seconds) => Settings.HudStaySeconds = seconds;
    public void SetOutputTraditional(bool on) => Settings.OutputTraditional = on;
    public void SetTrigger(TriggerMode mode) => Settings.Trigger = mode;
    public void SetMicMuted(bool on) => Settings.MicMuted = on;
    public void SetActiveTemplate(string id) => Settings.CloudActiveTemplate = id;
    public void SetLauncherEnabled(bool on) => Settings.LauncherEnabled = on;
    public void ShowQuickMenu(double screenX, double screenY) { }

    public void SetHotwords(bool enabled, string text, double score) { Settings.HotwordsEnabled = enabled; Settings.HotwordsText = text; Settings.HotwordsScore = score; }
    public void SetReplacements(bool enabled, string text) { Settings.ReplacementsEnabled = enabled; Settings.ReplacementsText = text; }
    public void SetPinyinFuzzy(bool on) => Settings.PinyinFuzzyEnabled = on;

    public void SetItn(bool on) => Settings.ItnEnabled = on;
    public void SetDefiller(bool on) => Settings.DefillerEnabled = on;
    public void SetSnippets(bool enabled, string json) { Settings.SnippetsEnabled = enabled; Settings.SnippetsJson = json; }

    public void SetCueEnabled(bool on) => Settings.CueEnabled = on;
    public void SetCueTheme(string theme) => Settings.CueTheme = theme;
    public void SetCueVolume(string preset) => Settings.CueVolume = preset;

    public bool ApiRunning => false;
    public int ApiBoundPort => Settings.ApiPort;
    public string ApiKey => Settings.ApiKey;
    public void SetApiEnabled(bool on) => Settings.ApiEnabled = on;
    public void SetApiAllowLAN(bool on) => Settings.ApiAllowLAN = on;
    public void SetApiPort(int port) => Settings.ApiPort = port;
    public string RegenerateApiKey() => Settings.RegenerateApiKey();

    public void ApplyCloudSettings() { }

    public bool MicGranted() => true;
    public void OpenMicPrivacy() { }

    public List<(string Id, string Name)> MicDevices() => new() { ("", "系统默认麦克风") };
    public string MicDeviceId => Settings.MicDeviceId;
    public void SetMicDevice(string id) => Settings.MicDeviceId = id;

    public string CurrentOverlayText => "";
    public bool DictationEnabled { get; set; } = true;
    public bool IsListening => false;
    public bool EngineReady => true;

    public void OpenSettings() { }
    public void OpenHistory() { }
    public void OpenPromptStudio() { }
    public void Quit() { }
}
