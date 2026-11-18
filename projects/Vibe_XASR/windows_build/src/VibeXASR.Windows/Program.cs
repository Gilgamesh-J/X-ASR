using System;
using System.Windows.Forms;

namespace VibeXASR.Windows;

/// <summary>
/// Entry point. Mirrors the macOS app's "menu-bar app, no main window" model:
/// we never show a primary form — only a tray icon, transient dialogs, and the
/// borderless overlay. <see cref="TrayApp"/> owns the engine, hotkey and overlay.
/// </summary>
internal static class Program
{
    [STAThread]
    private static void Main()
    {
        // .NET 8 WinForms bootstrap: high-DPI + default font in one call.
        // ApplicationConfiguration.Initialize() is source-generated from the
        // csproj <Application*> properties (HighDpiMode = PerMonitorV2).
        ApplicationConfiguration.Initialize();

        // Dev smoke test (headless): exercise the LOCAL AI-polish path end-to-end — load the CPM5 GGUF via
        // LLamaSharp (proves the loose native DLLs load), run one greedy inference + the full facade
        // (strip + guardrails). Result is written to %TEMP%\vx_refiner_test.txt. Set VIBEXASR_REFINER_TEST
        // to override the input text. No UI; exits when done.
        if (Environment.GetEnvironmentVariable("VIBEXASR_REFINER_TEST") is { } refinerTest)
        {
            var outFile = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "vx_refiner_test.txt");
            var input = string.IsNullOrWhiteSpace(refinerTest) ? "嗯就是那个我们明天上午十点开会然后呃讨论一下下个季度的方案" : refinerTest;
            var sb = new System.Text.StringBuilder();
            try
            {
                sb.AppendLine($"model present: {Refine.RefinerModel.Available()}  path: {Refine.RefinerModel.ResolvedPath}");
                var sw = System.Diagnostics.Stopwatch.StartNew();
                var lr = new Refine.LocalRefiner(Refine.RefinerModel.ResolvedPath);
                lr.LoadAsync().GetAwaiter().GetResult();
                sb.AppendLine($"load: ready={lr.IsReady} failed={lr.LoadFailed} in {sw.ElapsedMilliseconds} ms");
                if (lr.IsReady)
                {
                    sw.Restart();
                    var raw = lr.RefineAsync(Refine.Refiner.CpmSystemPrompt, input, System.Threading.CancellationToken.None).GetAwaiter().GetResult();
                    sb.AppendLine($"infer in {sw.ElapsedMilliseconds} ms");
                    sb.AppendLine($"INPUT : {input}");
                    sb.AppendLine($"RAW   : {raw}");
                    Refine.Refiner.Backend = lr;
                    Refine.Refiner.SystemProvider = () => Refine.Refiner.CpmSystemPrompt;
                    var polished = Refine.Refiner.PolishAsync(input).GetAwaiter().GetResult();
                    sb.AppendLine($"FINAL : {polished}");
                }
            }
            catch (Exception ex) { sb.AppendLine("EXCEPTION: " + ex); }
            try { System.IO.File.WriteAllText(outFile, sb.ToString()); } catch { }
            return;
        }

        // Dev hook: run the GGUF pre-tokenizer patcher in-place on a given file (to verify byte-correctness
        // against tools/patch_gguf_pre.py). VIBEXASR_GGUF_PATCH=<path>. Writes result to %TEMP%\vx_gguf_patch.txt.
        if (Environment.GetEnvironmentVariable("VIBEXASR_GGUF_PATCH") is { } gpPath && !string.IsNullOrWhiteSpace(gpPath))
        {
            var ok = Refine.GgufPatcher.EnsureWindowsCompatible(gpPath);
            try { System.IO.File.WriteAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "vx_gguf_patch.txt"),
                $"ok={ok} size={new System.IO.FileInfo(gpPath).Length}"); } catch { }
            return;
        }

        // UI-redesign preview hook (dev only): show the WPF prototype window, nothing else.
        if (Environment.GetEnvironmentVariable("VIBEXASR_OPEN") == "wpf")
        {
            try
            {
                var wpf = new System.Windows.Application();
                wpf.Run(new Ui.Wpf.SettingsWindow(new Ui.Wpf.PreviewController()));
            }
            catch (Exception ex)
            {
                try { System.IO.File.WriteAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "vx_wpf_err.txt"), ex.ToString()); } catch { }
            }
            return;
        }

        static string DevShotPath() => Environment.GetEnvironmentVariable("VIBEXASR_SHOT") ?? "";

        // Dev smoke test: host the WPF Settings window inside a real WinForms message loop
        // (exactly how TrayApp shows it live) to verify the interop path before shipping.
        if (Environment.GetEnvironmentVariable("VIBEXASR_OPEN") == "wpfhost")
        {
            // Screenshot hooks must follow the live scheme, exactly as the tray app does at startup.
            // VIBEXASR_THEME=dark|light forces it, so both schemes can be captured on one machine.
            // VIBEXASR_THEME=auto|dark|light stands in for the saved preference and travels the SAME
            // code path the tray app uses at startup (Theme.ApplyPreference), so a screenshot really
            // does prove the shipping resolution — not a lookalike that sets the two flags by hand.
            var forcedTheme = Environment.GetEnvironmentVariable("VIBEXASR_THEME");
            Ui.Theme.ApplyPreference(string.IsNullOrEmpty(forcedTheme) ? "auto" : forcedTheme, _ =>
            {
                // WinForms surfaces are constructed below, so there is nothing to re-apply yet.
            });
            var host = new Form { WindowState = FormWindowState.Minimized, ShowInTaskbar = false, Opacity = 0 };
            host.Load += (_, _) =>
            {
                var langDev = Environment.GetEnvironmentVariable("VIBEXASR_LANG");
                if (!string.IsNullOrEmpty(langDev)) Ui.L10n.Current = Ui.L10n.FromCode(langDev);
                var which = Environment.GetEnvironmentVariable("VIBEXASR_WIN");

                // VIBEXASR_FLIP: the capture is driven from here (before → switch → after), so the
                // window must NOT run its own one-shot capture, which would shut the app down first.
                bool flipMode = Environment.GetEnvironmentVariable("VIBEXASR_FLIP") == "1";
                string shotPath = DevShotPath();
                if (flipMode) Environment.SetEnvironmentVariable("VIBEXASR_SHOT", null);
                if (which == "popup")
                {
                    var pw = new Ui.Wpf.TrayPopupWindow(new Ui.Wpf.PreviewController());
                    pw.Closed += (_, _) => host.Close();
                    pw.ShowNear();
                    if (flipMode) { ScheduleFlip(host, pw, shotPath); return; }
                    return;
                }
                if (which == "download")
                {
                    var dw = new Ui.Wpf.DownloadWindow();
                    dw.Closed += (_, _) => host.Close();
                    dw.Show();
                    if (Ui.Wpf.DevShots.Seq > 1)
                    {
                        // Frame-sequence mode: drive a live progress ramp so the captured frames show the
                        // bar gliding between values instead of one settled state.
                        double p = 0;
                        var ramp = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(40) };
                        ramp.Tick += (_, _) =>
                        {
                            p = Math.Min(1, p + 0.07);
                            dw.Report(p, $"encoder.onnx  (2/4)  {p * 100:0}%");
                            if (p >= 1) ramp.Stop();
                        };
                        ramp.Start();
                        Ui.Wpf.DevShots.Capture(dw, 40, 30, host.Close);
                        return;
                    }
                    dw.Report(0.42, "encoder.onnx  (2/4)");
                    if (flipMode) { ScheduleFlip(host, dw, shotPath); return; }
                    Ui.Wpf.DevShots.Capture(dw, 350, 30, host.Close);
                    return;
                }
                if (which == "launcher")
                {
                    var lw = new Ui.Wpf.LauncherWindow(new Ui.Wpf.PreviewController());
                    lw.Closed += (_, _) => host.Close();
                    lw.Show();
                    if (flipMode) { ScheduleFlip(host, lw, shotPath); return; }
                    Ui.Wpf.DevShots.Capture(lw, 350, 30, host.Close);
                    return;
                }
                if (which is "overlay" or "overlay-oncall" or "overlay-inserted" or "overlay-repolishmenu" or "overlay-trans")
                {
                    var ov = new Ui.Wpf.OverlayWindow();
                    if (which == "overlay-oncall") { ov.ShowOnCall(); ov.SetText("把这个 function 改成 async,顺手把错误处理也补上。"); }
                    else if (which == "overlay-inserted") { ov.SetRepolishTemplates(new[] { ("auto", "⚡ 自动"), ("t1", "口语转书面"), ("t2", "会议纪要"), ("t3", "本地纠错复核") }); ov.SetText("把这个 function 改成 async,顺手把错误处理也补上"); ov.ShowInserted(autoHide: false, withUndo: true, withRepolish: true); }
                    else if (which == "overlay-repolishmenu") { ov.SetRepolishTemplates(new[] { ("auto", "⚡ 自动"), ("t1", "口语转书面"), ("t2", "会议纪要"), ("t3", "本地纠错复核") }); ov.DevShowRepolishMenu(); }
                    else if (which == "overlay-trans") { ov.SetRepolishTemplates(new[] { ("auto", "⚡ 自动"), ("t1", "口语转书面") }); ov.SetText("x"); ov.ShowInserted(autoHide: false, withUndo: true, withRepolish: true); ov.DevShowRepolishMenu(); ov.ShowListening(); ov.SetLevel(0.7); ov.SetText("把这个 function 改成 async"); }
                    else { ov.ShowListening(); ov.SetLevel(0.7); ov.SetText("把这个 function 改成 async,顺手把错误处理也补上,再写两句单元测试"); }
                    // Settle, then self-capture and close. VIBEXASR_SHOT_SEQ>1 grabs a 30 ms frame
                    // sequence starting on the first frame, which is how the entrance animation is verified.
                    if (flipMode) { ScheduleFlip(host, ov, shotPath); return; }
                    Ui.Wpf.DevShots.Capture(ov, Ui.Wpf.DevShots.Seq > 1 ? 16 : 350, 30, host.Close);
                    return;
                }
                if (which is "onboarding" or "oncall")
                {
                    // WinForms surfaces follow the same live scheme (Theme.IsDark is set just above).
                    System.Windows.Forms.Form f = which == "onboarding"
                        ? new Ui.OnboardingForm(new Ui.Wpf.PreviewController())
                        : new Ui.OnCallSessionForm(() => new Storage.HistoryStore().List().Take(6).ToList());
                    f.FormClosed += (_, _) => host.Close();
                    f.Show();
                    string shotPathWf = flipMode ? shotPath : DevShotPath();
                    if (!string.IsNullOrEmpty(shotPathWf))
                    {
                        static void Snap(System.Windows.Forms.Form form, string path)
                        {
                            try
                            {
                                using var bmp = new System.Drawing.Bitmap(form.Width, form.Height);
                                form.DrawToBitmap(bmp, new System.Drawing.Rectangle(0, 0, form.Width, form.Height));
                                bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
                            }
                            catch { }
                        }
                        var t = new System.Windows.Forms.Timer { Interval = 700 };
                        t.Tick += (_, _) =>
                        {
                            t.Stop();
                            Snap(f, shotPathWf);
                            if (!flipMode) { host.Close(); return; }
                            // Flip through the same entry point the tray app uses, so this capture proves
                            // the shipping live-switch path (WPF swaps its dictionary, WinForms re-applies).
                            Ui.Theme.ApplyPreference(Ui.Theme.IsDark ? "light" : "dark");
                            if (f is Ui.OnCallSessionForm oc) oc.ApplyScheme(); else if (f is Ui.OnboardingForm ob) ob.ApplyScheme();
                            var after = new System.Windows.Forms.Timer { Interval = 500 };
                            after.Tick += (_, _) =>
                            {
                                after.Stop();
                                Snap(f, System.IO.Path.Combine(System.IO.Path.GetDirectoryName(shotPathWf)!,
                                    System.IO.Path.GetFileNameWithoutExtension(shotPathWf) + "_flipped" + System.IO.Path.GetExtension(shotPathWf)));
                                host.Close();
                            };
                            after.Start();
                        };
                        t.Start();
                    }
                    return;
                }
                try
                {
                    System.Windows.Window w = which == "history"
                        ? new Ui.Wpf.HistoryWindow(new Storage.HistoryStore())
                        : new Ui.Wpf.SettingsWindow(new Ui.Wpf.PreviewController());
                    w.Closed += (_, _) => host.Close();
                    w.Show();
                    w.Activate();
                    if (flipMode) ScheduleFlip(host, w, shotPath);
                    // VIBEXASR_PICK=<n>: drive the 外观 dropdown itself (a real SelectionChanged, not a
                    // direct Palette.Apply) so the whole preference → scheme → repaint path is exercised,
                    // including the re-entrancy of rebuilding the tree that owns the ComboBox.
                    else if (int.TryParse(Environment.GetEnvironmentVariable("VIBEXASR_PICK"), out int pick))
                        PickCombo(w, pick, shotPath, host);
                }
                catch (Exception ex)
                {
                    // A dev hook that dies silently is worse than useless — record why.
                    try { System.IO.File.WriteAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "vx_dev_err.txt"), ex.ToString()); } catch { }
                    host.Close();
                }


            };
            Application.Run(host);
            return;
        }

        // VIBEXASR_FLIP=1: capture, flip the scheme with the window still on screen, capture again.
        // This is the only way to prove a live switch repaints open windows rather than only affecting
        // the next window that opens. The window is passed in explicitly: these hooks run inside a
        // WinForms message pump, so Application.Current is null and cannot be used to find it.
        static void ScheduleFlip(Form host, System.Windows.Window target, string shotPath)
        {
            Environment.SetEnvironmentVariable("VIBEXASR_SHOT", null);   // the window's own self-capture would win the race
            var before = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(700) };
            before.Tick += (_, _) =>
            {
                before.Stop();
                Ui.Wpf.DevShots.Save(target, shotPath);
                // Same entry point as the tray app, so the "after" frame proves the shipping path.
                Ui.Theme.ApplyPreference(Ui.Theme.IsDark ? "light" : "dark");
                var after = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
                after.Tick += (_, _) =>
                {
                    after.Stop();
                    string flipped = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(shotPath)!,
                        System.IO.Path.GetFileNameWithoutExtension(shotPath) + "_flipped" + System.IO.Path.GetExtension(shotPath));
                    Ui.Wpf.DevShots.Save(target, flipped);
                    host.Close();
                };
                after.Start();
            };
            before.Start();
        }

        // Select item <index> in the first ComboBox of the live window, then capture the result.
        // Used to prove that switching 外观 from inside the settings tree repaints without faulting.
        static void PickCombo(System.Windows.Window w, int index, string shotPath, Form host)
        {
            Environment.SetEnvironmentVariable("VIBEXASR_SHOT", null);   // the window's self-capture would race us
            var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(700) };
            t.Tick += (_, _) =>
            {
                t.Stop();
                try
                {
                    var combo = FindFirst<System.Windows.Controls.ComboBox>(w);
                    if (combo is not null && combo.Items.Count > index) combo.SelectedIndex = index;
                }
                catch (Exception ex)
                {
                    try { System.IO.File.WriteAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "vx_dev_err.txt"), ex.ToString()); } catch { }
                }
                var shot = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(900) };
                shot.Tick += (_, _) =>
                {
                    shot.Stop();
                    if (!string.IsNullOrEmpty(shotPath)) Ui.Wpf.DevShots.Save(w, shotPath);
                    host.Close();
                };
                shot.Start();
            };
            t.Start();
        }

        static T? FindFirst<T>(System.Windows.DependencyObject root) where T : System.Windows.DependencyObject
        {
            if (root is T hit) return hit;
            int n = System.Windows.Media.VisualTreeHelper.GetChildrenCount(root);
            for (int i = 0; i < n; i++)
                if (FindFirst<T>(System.Windows.Media.VisualTreeHelper.GetChild(root, i)) is T found) return found;
            return null;
        }

        // Single-instance guard so two tray icons don't fight over the hotkey.
        using var single = new System.Threading.Mutex(initiallyOwned: true,
            "VibeXASR.Windows.SingleInstance", out bool isNew);
        if (!isNew)
        {
            // TODO(win): optionally signal the existing instance to show Settings.
            return;
        }

        Diag.Log("=== launch (VibeXASR " + Application.ProductVersion + ") ===");
        using var app = new TrayApp();
        app.Start();

        // Pump the WinForms message loop. TrayApp.Start() does NOT block; the
        // ApplicationContext keeps the process alive until Quit calls ExitThread.
        Application.Run(app.Context);
    }
}