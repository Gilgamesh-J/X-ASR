using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace VibeXASR.Windows.Storage;

/// <summary>Dictation insertion behaviour. Mirrors the macOS app's three modes.</summary>
public enum DictationMode
{
    /// <summary>Insert the whole recognized result once, on hotkey release.</summary>
    Paste,

    /// <summary>Stream characters to the caret as they are recognized (with backspace diffing).</summary>
    Type,

    /// <summary>Always-on, VAD-segmented; overlay shows live text, user copies manually.</summary>
    OnCall,
}

/// <summary>Streaming model tier (chunk size in ms). Larger = more accurate, more latency.</summary>
public enum ModelTier
{
    Ms160 = 160,
    Ms480 = 480,
    Ms960 = 960,
    Ms1920 = 1920,
}

/// <summary>VAD backend choice.</summary>
public enum VadKind
{
    Silero,
    FireRed,
}

/// <summary>
/// Persisted user settings. Serialized to %APPDATA%/VibeXASR/settings.json.
/// Keep this a plain DTO so System.Text.Json round-trips it cleanly.
/// </summary>
public sealed class Settings
{
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public DictationMode Mode { get; set; } = DictationMode.Paste;

    [JsonConverter(typeof(JsonStringEnumConverter))]
    public ModelTier Tier { get; set; } = ModelTier.Ms960; // 960ms default, matches macOS.

    /// <summary>Model download source: "official" (CDN 加速线路, default) | "modelscope" | "huggingface". macOS parity (build 203).</summary>
    public string ModelSource { get; set; } = "official";

    [JsonConverter(typeof(JsonStringEnumConverter))]
    public VadKind Vad { get; set; } = VadKind.FireRed; // FireRedVAD default, matches macOS

    /// <summary>Back-compat alias. Both Silero and FireRed now work on Windows (the FireRed macOS
    /// shim is ported as firered_vad.dll); the present-or-fall-back-to-Silero decision lives in
    /// <see cref="Models.ModelPaths.ResolveVad"/>.</summary>
    [JsonIgnore]
    public VadKind EffectiveVad => Vad;

    /// <summary>
    /// Push-to-talk key. Stored as a Win32 virtual-key code (VK_*).
    /// Default = Right Ctrl (VK_RCONTROL = 0xA3). TODO(win): confirm the default
    /// feels right on a real keyboard; some users prefer a function key (e.g. F8 = 0x77).
    /// </summary>
    public int HotkeyVk { get; set; } = 0xA3;

    /// <summary>If true, the OnCall overlay starts automatically at launch.</summary>
    public bool OnCallAutoStart { get; set; } = false;

    /// <summary>UI language code (auto, en, zh, ja, ko). Auto follows the system.</summary>
    public string Language { get; set; } = "auto";

    /// <summary>Keep the dictated text on the clipboard after each result (issue #12 parity).</summary>
    public bool ClipboardOverwrite { get; set; } = false;

    /// <summary>Persist dictation history locally. When off, records live 60 s then vanish.</summary>
    public bool HistoryEnabled { get; set; } = true;

    /// <summary>Start Vibe XASR with Windows sign-in (HKCU Run key).</summary>
    public bool LaunchAtLogin { get; set; } = false;

    /// <summary>Desktop floating launcher pill (so users can always find/open the app). Default on; closable.</summary>
    public bool LauncherEnabled { get; set; } = true;
    /// <summary>Persisted launcher position (screen DIPs). null = auto (bottom-right above the tray).</summary>
    public double? LauncherX { get; set; }
    public double? LauncherY { get; set; }

    /// <summary>Show the notification-area (tray) icon. Always on for now (the menu lives there).</summary>
    public bool ShowTrayIcon { get; set; } = true;

    /// <summary>Set once the first-run welcome/onboarding window has been shown.</summary>
    public bool Welcomed { get; set; } = false;

    /// <summary>Selected microphone endpoint ID. Empty = the system default recording device.</summary>
    public string MicDeviceId { get; set; } = "";

    // ---- Local share API (v1.4.0: local read-only HTTP server for coding agents / AI assistants) ----

    /// <summary>Master switch for the embedded local HTTP API. Off by default.</summary>
    public bool ApiEnabled { get; set; } = false;

    /// <summary>Allow LAN (0.0.0.0) access. Off → bound to 127.0.0.1 only.</summary>
    public bool ApiAllowLAN { get; set; } = false;

    /// <summary>TCP port for the local API (uncommon default → fewer conflicts).</summary>
    public int ApiPort { get; set; } = 8473;

    private string _apiKey = "";
    /// <summary>Bearer key required on every request; generated on first access, never empty.</summary>
    public string ApiKey
    {
        get { if (string.IsNullOrEmpty(_apiKey)) _apiKey = NewApiKey(); return _apiKey; }
        set => _apiKey = value ?? "";
    }

    /// <summary>Rotate the key (invalidates any skill already shared with the old key). Persists.</summary>
    public string RegenerateApiKey() { _apiKey = NewApiKey(); Save(); return _apiKey; }

    private static string NewApiKey()
    {
        const string chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no look-alikes
        var bytes = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
        var sb = new System.Text.StringBuilder(32);
        foreach (var b in bytes) sb.Append(chars[b % chars.Length]);
        return sb.ToString();
    }

    // ---- Cue sound (subtle chime on dictation start/stop) ----

    /// <summary>Play a soft cue when dictation starts and ends. On by default.</summary>
    public bool CueEnabled { get; set; } = true;

    /// <summary>Cue timbre: "tick" | "chime" | "soft" | "drop" | "marimba". Default "chime".</summary>
    public string CueTheme { get; set; } = "chime";

    /// <summary>Cue volume preset: "low" (default) | "med" | "high".</summary>
    public string CueVolume { get; set; } = "low";

    // ---- Dictionary (词典): hotword bias + pinyin homophone correction + replacements ----

    /// <summary>Master switch for hotword contextual biasing. On → engine rebuilds with the hotwords
    /// file (modified_beam_search); off keeps the byte-for-byte greedy recipe.</summary>
    public bool HotwordsEnabled { get; set; } = false;

    /// <summary>Newline-separated hotword phrases (names / jargon to bias the ASR toward). Seeded
    /// with examples so the 词典 page demonstrates the feature.</summary>
    public string HotwordsText { get; set; } = "贾扬清\n沈向洋\nPyTorch\nOpenAI\ntransformer\n向量数据库\nvibe coding\nCursor\nClaude Code\nGitHub Copilot\nChatGPT\nCodex\nAgent\nMCP\nVS Code\nprompt";

    /// <summary>Hotword boost: 3 (low) / 5 (mid) / 7 (high) for CJK; English auto-capped ≤2.5.</summary>
    public double HotwordsScore { get; set; } = 5.0;

    /// <summary>Homophone correction (rewrite same-sounding CJK runs to a dictionary word). On by
    /// default but inert until the user adds multi-char hotwords that drive it.</summary>
    public bool PinyinFuzzyEnabled { get; set; } = true;

    /// <summary>Master switch for post-recognition text replacement.</summary>
    public bool ReplacementsEnabled { get; set; } = false;

    /// <summary>Newline-separated replacement rules, each "from =&gt; to".</summary>
    public string ReplacementsText { get; set; } = "";

    /// <summary>Number normalization (ITN): spoken Chinese numerals → digits on the FINAL result
    /// (一百二十三→123, 三点半→3:30, 百分之二十→20%). Pure post-processing. On by default.</summary>
    public bool ItnEnabled { get; set; } = true;

    /// <summary>Remove filler words (嗯/呃/唉 + stutter repeats) from the FINAL result. On by default.</summary>
    public bool DefillerEnabled { get; set; } = true;

    /// <summary>Master switch for voice snippets (口令: a spoken trigger → a saved expansion).
    /// On by default (an empty list is a no-op).</summary>
    public bool SnippetsEnabled { get; set; } = true;

    /// <summary>Snippets as JSON: <c>[{"t":"trigger","x":"expansion"}]</c>. Persisted; parsed live.</summary>
    public string SnippetsJson { get; set; } = "[]";

    // ---- AI 润色 (cloud LLM refinement, Beta) ----

    /// <summary>Master switch for cloud LLM refinement of the FINAL text (Beta). Off by default — it
    /// rewrites spoken text and sends it to a third-party API, so it is strictly opt-in.</summary>
    public bool CloudEnabled { get; set; } = false;

    /// <summary>Provider key (see Refine.LlmProviders): "openai" / "deepseek" / "ark" / … / "custom".</summary>
    public string CloudProvider { get; set; } = "openai";

    /// <summary>OpenAI-compatible base URL (without the trailing /chat/completions).</summary>
    public string CloudBaseURL { get; set; } = "https://api.openai.com/v1";

    /// <summary>Model id (free text).</summary>
    public string CloudModel { get; set; } = "gpt-4o-mini";

    /// <summary>Sampling temperature 0..1 (refinement default 0.3).</summary>
    public double CloudTemperature { get; set; } = 0.3;

    /// <summary>Max output tokens (default 2048).</summary>
    public int CloudMaxTokens { get; set; } = 2048;

    /// <summary>The four "auto" processing toggles (numbers / fillers / restatement / hotwords).</summary>
    public bool CloudNumbers { get; set; } = true;
    public bool CloudFillers { get; set; } = true;
    public bool CloudRestate { get; set; } = true;
    public bool CloudHotwords { get; set; } = true;

    /// <summary>Record recent requests (for troubleshooting). On by default.</summary>
    public bool CloudLogEnabled { get; set; } = true;

    /// <summary>API key — NEVER written to settings.json; stored DPAPI-encrypted (per-user) via SecretStore,
    /// mirroring macOS's Keychain handling ("encrypted on this machine only, never uploaded").</summary>
    [JsonIgnore]
    public string CloudApiKey
    {
        get => SecretStore.Get("cloud_api_key");
        set => SecretStore.Set("cloud_api_key", value ?? "");
    }

    /// <summary>Active prompt template id: "auto" (built live from the 4 toggles) | a template id.</summary>
    public string CloudActiveTemplate { get; set; } = "auto";
    /// <summary>User-edited override of the "auto" prompt (empty = use the toggle-built prompt).</summary>
    public string CloudAutoOverride { get; set; } = "";
    /// <summary>Saved prompt templates as JSON [{id,name,content}]. Empty = the 3 seed templates.</summary>
    public string CloudTemplatesJson { get; set; } = "";
    /// <summary>User custom providers as JSON [{id,label,baseURL}].</summary>
    public string CloudCustomProvidersJson { get; set; } = "";
    /// <summary>Saved named cloud profiles as JSON (each profile's key stored separately in SecretStore).</summary>
    public string CloudProfilesJson { get; set; } = "";

    // ---- persistence ----

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        // Never let a NaN/Infinity double (e.g. an unset position) make Save() throw and silently
        // drop ALL settings — write/read them as named literals instead.
        NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowNamedFloatingPointLiterals,
    };

    public static string FilePath =>
        Path.Combine(AppPaths.DataDir, "settings.json");

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var json = File.ReadAllText(FilePath);
                var s = JsonSerializer.Deserialize<Settings>(json, JsonOpts);
                if (s is not null) return s;
            }
        }
        catch
        {
            // Corrupt settings -> fall back to defaults rather than crash the tray.
            // TODO(win): log to %APPDATA%/VibeXASR/log.txt for diagnosis.
        }
        return new Settings();
    }

    public void Save()
    {
        Directory.CreateDirectory(AppPaths.DataDir);
        var json = JsonSerializer.Serialize(this, JsonOpts);
        // Write-then-rename for crash safety.
        var tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, json);
        File.Copy(tmp, FilePath, overwrite: true);
        File.Delete(tmp);
    }
}

/// <summary>Shared %APPDATA%/VibeXASR resolution.</summary>
public static class AppPaths
{
    public static string DataDir =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "VibeXASR");
}
