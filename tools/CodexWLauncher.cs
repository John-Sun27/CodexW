using System;
using System.Diagnostics;
using System.IO;

namespace CodexWLauncher
{
    internal static class Program
    {
        [STAThread]
        private static int Main()
        {
            try
            {
                string exePath = System.Reflection.Assembly.GetExecutingAssembly().Location;
                string root = Path.GetDirectoryName(exePath) ?? AppDomain.CurrentDomain.BaseDirectory;
                string script = Path.Combine(root, "windows", "CodexW.ps1");

                if (!File.Exists(script))
                {
                    string fallback = Path.Combine(root, "CodexW.ps1");
                    if (File.Exists(fallback))
                    {
                        script = fallback;
                    }
                }

                if (!File.Exists(script))
                {
                    return 2;
                }

                string powershell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                    "System32",
                    "WindowsPowerShell",
                    "v1.0",
                    "powershell.exe");

                if (!File.Exists(powershell))
                {
                    powershell = "powershell.exe";
                }

                var startInfo = new ProcessStartInfo
                {
                    FileName = powershell,
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File " + Quote(script),
                    WorkingDirectory = Path.GetDirectoryName(script) ?? root,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };

                Process.Start(startInfo);
                return 0;
            }
            catch
            {
                return 1;
            }
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }
    }
}
