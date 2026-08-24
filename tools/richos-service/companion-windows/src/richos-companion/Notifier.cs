using System;
using System.Diagnostics;

namespace RichOSCompanion
{
    /// <summary>
    /// Loud, out-of-band alerting for the never-silent guarantee (§6.3/§6.4). The companion IS the
    /// outside-the-browser watchdog, so a detected stall must surface where a human sees it even if a
    /// call app is wedged: <b>stderr always</b> (the guaranteed channel), plus a best-effort Windows
    /// toast via PowerShell's <c>Windows.UI.Notifications</c> (no extra dependency; silently skipped if
    /// unavailable — stderr already fired). The chime stays OFF by default — an open mic would pick it
    /// up (§6.4). The peer of the macOS companion's <c>Notifier.swift</c>.
    /// </summary>
    internal static class Notifier
    {
        public static void Alarm(string message)
        {
            Console.Error.WriteLine($"[!!] RichOS companion ALARM: {message}");
            Toast("RichOS capture alarm", message);
        }

        public static void Info(string message)
        {
            Console.Error.WriteLine($"[--] {message}");
        }

        private static void Toast(string title, string message)
        {
            try
            {
                // Minimal WinRT toast via PowerShell. Best-effort: any failure is swallowed (stderr
                // already carried the alarm), so a missing/locked-down PowerShell never blocks capture.
                string safeTitle = title.Replace("'", "''");
                string safeMsg = message.Replace("'", "''");
                string script =
                    "$ErrorActionPreference='SilentlyContinue';" +
                    "[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]|Out-Null;" +
                    "$t=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);" +
                    "$n=$t.GetElementsByTagName('text');" +
                    $"$n.Item(0).AppendChild($t.CreateTextNode('{safeTitle}'))|Out-Null;" +
                    $"$n.Item(1).AppendChild($t.CreateTextNode('{safeMsg}'))|Out-Null;" +
                    "$toast=[Windows.UI.Notifications.ToastNotification]::new($t);" +
                    "[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('RichOS').Show($toast);";
                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = $"-NoProfile -NonInteractive -WindowStyle Hidden -Command \"{script}\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                Process.Start(psi);
            }
            catch
            {
                /* best-effort; stderr already carried the alarm */
            }
        }
    }
}
