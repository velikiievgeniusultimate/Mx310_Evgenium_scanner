using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using System.Windows.Forms;

[assembly: AssemblyTitle("Mx310_Evgenium_scanner Setup")]
[assembly: AssemblyProduct("Mx310_Evgenium_scanner")]
[assembly: AssemblyCompany("Evgenium")]
[assembly: AssemblyVersion("1.0.4.0")]
[assembly: AssemblyFileVersion("1.0.4.0")]

internal static class Bootstrapper
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string desktop = ReadArgument(args, "--desktop-base64");
            if (string.IsNullOrEmpty(desktop)) desktop = GetInteractiveDesktop();

            if (!IsAdministrator())
            {
                ProcessStartInfo elevated = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location);
                elevated.UseShellExecute = true;
                elevated.Verb = "runas";
                elevated.Arguments = "--elevated --desktop-base64 " + Convert.ToBase64String(Encoding.UTF8.GetBytes(desktop));
                Process child = Process.Start(elevated);
                child.WaitForExit();
                return child.ExitCode;
            }

            if (!IsArm64Windows())
                throw new InvalidOperationException("Этот установщик предназначен только для Windows 11 ARM64.");

            string payloadRoot = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "MX310-Native", "bootstrap-payload");
            if (Directory.Exists(payloadRoot)) Directory.Delete(payloadRoot, true);
            Directory.CreateDirectory(payloadRoot);

            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
            {
                if (resource == null) throw new InvalidDataException("В установщике отсутствует payload.zip.");
                using (ZipArchive archive = new ZipArchive(resource, ZipArchiveMode.Read))
                {
                    foreach (ZipArchiveEntry entry in archive.Entries)
                    {
                        string destination = Path.GetFullPath(Path.Combine(payloadRoot, entry.FullName));
                        if (!destination.StartsWith(payloadRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidDataException("Недопустимый путь в установщике: " + entry.FullName);
                        if (string.IsNullOrEmpty(entry.Name)) { Directory.CreateDirectory(destination); continue; }
                        Directory.CreateDirectory(Path.GetDirectoryName(destination));
                        entry.ExtractToFile(destination, true);
                    }
                }
            }

            string script = Path.Combine(payloadRoot, "Install-MX310-Native.ps1");
            ProcessStartInfo install = new ProcessStartInfo("powershell.exe");
            install.UseShellExecute = false;
            install.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" -Elevated -DesktopPath \"" + desktop.Replace("\"", "\"\"") + "\"";
            Process installer = Process.Start(install);
            installer.WaitForExit();
            return installer.ExitCode;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Mx310_Evgenium_scanner — ошибка установки", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static bool IsAdministrator()
    {
        WindowsPrincipal principal = new WindowsPrincipal(WindowsIdentity.GetCurrent());
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static string GetInteractiveDesktop()
    {
        object value = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders", "Desktop", null);
        string path = value as string;
        if (!string.IsNullOrEmpty(path)) path = Environment.ExpandEnvironmentVariables(path);
        if (string.IsNullOrEmpty(path)) path = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        if (string.IsNullOrEmpty(path)) path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Desktop");
        return path;
    }

    private static string ReadArgument(string[] args, string name)
    {
        for (int i = 0; i + 1 < args.Length; i++)
            if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase))
                return Encoding.UTF8.GetString(Convert.FromBase64String(args[i + 1]));
        return null;
    }

    private static bool IsArm64Windows()
    {
        ushort processMachine;
        ushort nativeMachine;
        if (IsWow64Process2(GetCurrentProcess(), out processMachine, out nativeMachine))
            return nativeMachine == 0xAA64;

        string architecture = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITEW6432");
        if (string.IsNullOrEmpty(architecture)) architecture = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE");
        return string.Equals(architecture, "ARM64", StringComparison.OrdinalIgnoreCase);
    }

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
}
