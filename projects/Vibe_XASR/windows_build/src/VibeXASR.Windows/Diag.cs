using System;
using System.IO;
using VibeXASR.Windows.Storage;

namespace VibeXASR.Windows;

/// <summary>
/// Tiny append-only diagnostic log at <c>%APPDATA%\VibeXASR\log.txt</c>. Used to trace the
/// hotkey / engine / mic path so "nothing happened" issues are diagnosable from the file.
/// Best-effort and exception-safe — never throws into the caller.
/// </summary>
public static class Diag
{
    private static readonly object Gate = new();
    public static string FilePath => Path.Combine(AppPaths.DataDir, "log.txt");

    public static void Log(string msg)
    {
        try
        {
            Directory.CreateDirectory(AppPaths.DataDir);
            var line = $"{DateTime.Now:HH:mm:ss.fff} [{Environment.CurrentManagedThreadId,2}] {msg}{Environment.NewLine}";
            lock (Gate) File.AppendAllText(FilePath, line);
        }
        catch { /* logging must never break the app */ }
    }
}
