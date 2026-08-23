using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;
[assembly: AssemblyTitle("Mx310_Evgenium_scanner Debug Uninstaller")]
[assembly: AssemblyProduct("Mx310_Evgenium_scanner")]
[assembly: AssemblyVersion("1.0.4.0")]
[assembly: AssemblyFileVersion("1.0.4.0")]
internal static class DebugUninstaller
{
    [STAThread] private static int Main()
    {
        try {
            if(!IsAdministrator()){
                var psi=new ProcessStartInfo(Assembly.GetExecutingAssembly().Location){UseShellExecute=true,Verb="runas"};
                var child=Process.Start(psi);child.WaitForExit();return child.ExitCode;
            }
            string work=Path.Combine(Path.GetTempPath(),"Mx310_uninstall_"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(work);
            string uninstall=Extract("Uninstall-MX310.ps1",Path.Combine(work,"Uninstall-MX310.ps1"));
            string verify=Extract("Verify-MX310-Removal.ps1",Path.Combine(work,"Verify-MX310-Removal.ps1"));
            string desktop=Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            string report=Path.Combine(Directory.Exists(desktop)?desktop:Path.GetTempPath(),"Mx310-removal-report.txt");
            int removeExit=Run(uninstall,"-Elevated -ReportPath \""+report+"\"");if(removeExit==2)return 0;
            int verifyExit=Run(verify,"-ReportPath \""+report+"\"");
            string summary=File.Exists(report)?File.ReadAllText(report,Encoding.UTF8):"Verification report was not created.";
            MessageBox.Show(summary,"Mx310 removal verification",MessageBoxButtons.OK,verifyExit==0?MessageBoxIcon.Information:MessageBoxIcon.Warning);
            return removeExit==0&&verifyExit==0?0:1;
        }catch(Exception ex){MessageBox.Show(ex.ToString(),"Mx310 debug uninstaller error",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1;}
    }
    private static string Extract(string name,string path){using(Stream i=Assembly.GetExecutingAssembly().GetManifestResourceStream(name)){if(i==null)throw new InvalidDataException("Missing resource: "+name);using(FileStream o=File.Create(path))i.CopyTo(o);}return path;}
    private static int Run(string script,string args){var p=Process.Start(new ProcessStartInfo("powershell.exe","-NoProfile -ExecutionPolicy Bypass -File \""+script+"\" "+args){UseShellExecute=false});p.WaitForExit();return p.ExitCode;}
    private static bool IsAdministrator(){return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);}
}
