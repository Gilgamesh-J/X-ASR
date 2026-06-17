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

        // Dev smoke test: host the WPF Settings window inside a real WinForms message loop
        // (exactly how TrayApp shows it live) to verify the interop path before shipping.
        if (Environment.GetEnvironmentVariable("VIBEXASR_OPEN") == "wpfhost")
        {
            var host = new Form { WindowState = FormWindowState.Minimized, ShowInTaskbar = false, Opacity = 0 };
            host.Load += (_, _) =>
            {
                var langDev = Environment.GetEnvironmentVariable("VIBEXASR_LANG");
                if (!string.IsNullOrEmpty(langDev)) Ui.L10n.Current = Ui.L10n.FromCode(langDev);
                var which = Environment.GetEnvironmentVariable("VIBEXASR_WIN");
                if (which == "popup")
                {
                    var pw = new Ui.Wpf.TrayPopupWindow(new Ui.Wpf.PreviewController());
                    pw.Closed += (_, _) => host.Close();
                    pw.ShowNear();
                    return;
                }
                if (which == "download")
                {
                    var dw = new Ui.Wpf.DownloadWindow();
                    dw.Closed += (_, _) => host.Close();
                    dw.Show();
                    dw.Report(0.42, "encoder.onnx  (2/4)");
                    var cap = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
                    cap.Tick += (_, _) =>
                    {
                        cap.Stop();
                        var shot = Environment.GetEnvironmentVariable("VIBEXASR_SHOT");
                        if (!string.IsNullOrEmpty(shot))
                            try
                            {
                                dw.UpdateLayout();
                                int w = (int)Math.Ceiling(dw.ActualWidth), h = (int)Math.Ceiling(dw.ActualHeight);
                                var rtb = new System.Windows.Media.Imaging.RenderTargetBitmap(w, h, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
                                rtb.Render(dw);
                                var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                                enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(rtb));
                                using var fs = System.IO.File.Create(shot); enc.Save(fs);
                            }
                            catch { }
                        host.Close();
                    };
                    cap.Start();
                    return;
                }
                if (which == "launcher")
                {
                    var lw = new Ui.Wpf.LauncherWindow(new Ui.Wpf.PreviewController());
                    lw.Closed += (_, _) => host.Close();
                    lw.Show();
                    var cap = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
                    cap.Tick += (_, _) =>
                    {
                        cap.Stop();
                        var shot = Environment.GetEnvironmentVariable("VIBEXASR_SHOT");
                        if (!string.IsNullOrEmpty(shot))
                            try
                            {
                                lw.UpdateLayout();
                                int w = (int)Math.Ceiling(lw.ActualWidth), h = (int)Math.Ceiling(lw.ActualHeight);
                                var rtb = new System.Windows.Media.Imaging.RenderTargetBitmap(w, h, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
                                rtb.Render(lw);
                                var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                                enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(rtb));
                                using var fs = System.IO.File.Create(shot); enc.Save(fs);
                            }
                            catch { }
                        host.Close();
                    };
                    cap.Start();
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
                    // let layout + one anim frame settle, then self-capture and close.
                    var cap = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
                    cap.Tick += (_, _) =>
                    {
                        cap.Stop();
                        var shot = Environment.GetEnvironmentVariable("VIBEXASR_SHOT");
                        if (!string.IsNullOrEmpty(shot))
                            try
                            {
                                ov.UpdateLayout();
                                int w = (int)Math.Ceiling(ov.ActualWidth), h = (int)Math.Ceiling(ov.ActualHeight);
                                var rtb = new System.Windows.Media.Imaging.RenderTargetBitmap(w, h, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
                                rtb.Render(ov);
                                var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                                enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(rtb));
                                using var fs = System.IO.File.Create(shot); enc.Save(fs);
                            }
                            catch { }
                        host.Close();
                    };
                    cap.Start();
                    return;
                }
                System.Windows.Window w = which == "history"
                    ? new Ui.Wpf.HistoryWindow(new Storage.HistoryStore())
                    : new Ui.Wpf.SettingsWindow(new Ui.Wpf.PreviewController());
                w.Closed += (_, _) => host.Close();
                w.Show();
                w.Activate();
            };
            Application.Run(host);
            return;
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
