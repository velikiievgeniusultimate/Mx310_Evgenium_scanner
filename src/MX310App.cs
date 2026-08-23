using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Reflection;

[assembly: AssemblyTitle("Mx310 Evgenium Scanner")]
[assembly: AssemblyProduct("Mx310_Evgenium_scanner")]
[assembly: AssemblyCompany("Evgenium")]
[assembly: AssemblyVersion("1.0.4.0")]
[assembly: AssemblyFileVersion("1.0.4.0")]

namespace MX310Native
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length >= 2 && string.Equals(args[0], "--probe", StringComparison.OrdinalIgnoreCase))
                return RunProbe(args[1]);

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            try
            {
                Application.Run(new MainForm());
                return 0;
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.ToString(), "Canon MX310 ARM64 â€” Ð¾ÑˆÐ¸Ð±ÐºÐ°", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }

        private static int RunProbe(string path)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                using (StreamWriter writer = new StreamWriter(path, false, new UTF8Encoding(true)))
                {
                    Action<string> logger = delegate(string text)
                    {
                        writer.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff") + " " + text);
                        writer.Flush();
                    };
                    logger("Canon MX310 native probe");
                    logger("Pointer size: " + (IntPtr.Size * 8) + " bit");
                    logger("PROCESSOR_ARCHITECTURE: " + Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE"));
                    using (LibUsbTransport transport = new LibUsbTransport(logger))
                    {
                        PixmaMx310 scanner = new PixmaMx310(transport, logger, null);
                        scanner.Probe();
                    }
                    logger("PROBE SUCCESS");
                }
                return 0;
            }
            catch (Exception ex)
            {
                try
                {
                    File.AppendAllText(path, "PROBE FAILED\r\n" + ex + "\r\n", new UTF8Encoding(true));
                }
                catch { }
                return 1;
            }
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly ComboBox resolution;
        private readonly Button scanButton;
        private readonly Button folderButton;
        private readonly Label status;
        private readonly ProgressBar progress;
        private string lastOutput;

        public MainForm()
        {
            Text = "Canon MX310 â€” Ð½Ð°Ñ‚Ð¸Ð²Ð½Ð¾Ðµ ÑÐºÐ°Ð½Ð¸Ñ€Ð¾Ð²Ð°Ð½Ð¸Ðµ ARM64";
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(560, 285);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;

            Label title = new Label();
            title.Text = "Canon PIXMA MX310";
            title.Font = new Font(Font.FontFamily, 16, FontStyle.Bold);
            title.AutoSize = true;
            title.Location = new Point(24, 20);
            Controls.Add(title);

            Label transport = new Label();
            transport.Text = "Windows 11 ARM64 â€¢ WinUSB â€¢ Ð½Ð°Ñ‚Ð¸Ð²Ð½Ñ‹Ð¹ Ð¿Ñ€Ð¾Ñ‚Ð¾ÐºÐ¾Ð» PIXMA generation 3";
            transport.AutoSize = true;
            transport.ForeColor = Color.DimGray;
            transport.Location = new Point(27, 55);
            Controls.Add(transport);

            Label dpiLabel = new Label();
            dpiLabel.Text = "Ð Ð°Ð·Ñ€ÐµÑˆÐµÐ½Ð¸Ðµ:";
            dpiLabel.AutoSize = true;
            dpiLabel.Location = new Point(27, 96);
            Controls.Add(dpiLabel);

            resolution = new ComboBox();
            resolution.DropDownStyle = ComboBoxStyle.DropDownList;
            resolution.Items.AddRange(new object[] { "75 dpi â€” Ñ‡ÐµÑ€Ð½Ð¾Ð²Ð¸Ðº", "150 dpi â€” Ð±Ñ‹ÑÑ‚Ñ€Ð¾", "300 dpi â€” Ð´Ð¾ÐºÑƒÐ¼ÐµÐ½Ñ‚" });
            resolution.SelectedIndex = 2;
            resolution.Location = new Point(130, 92);
            resolution.Width = 205;
            Controls.Add(resolution);

            scanButton = new Button();
            scanButton.Text = "Ð¡ÐºÐ°Ð½Ð¸Ñ€Ð¾Ð²Ð°Ñ‚ÑŒ ÑÐ¾ ÑÑ‚ÐµÐºÐ»Ð°";
            scanButton.Location = new Point(355, 90);
            scanButton.Size = new Size(175, 30);
            scanButton.Click += ScanClicked;
            Controls.Add(scanButton);

            progress = new ProgressBar();
            progress.Location = new Point(30, 145);
            progress.Size = new Size(500, 20);
            progress.Minimum = 0;
            progress.Maximum = 100;
            Controls.Add(progress);

            status = new Label();
            status.Text = "ÐŸÐ¾Ð»Ð¾Ð¶Ð¸Ñ‚Ðµ Ð´Ð¾ÐºÑƒÐ¼ÐµÐ½Ñ‚ Ð½Ð° ÑÑ‚ÐµÐºÐ»Ð¾ Ð¸ Ð½Ð°Ð¶Ð¼Ð¸Ñ‚Ðµ Â«Ð¡ÐºÐ°Ð½Ð¸Ñ€Ð¾Ð²Ð°Ñ‚ÑŒÂ».";
            status.Location = new Point(27, 177);
            status.Size = new Size(500, 40);
            Controls.Add(status);

            folderButton = new Button();
            folderButton.Text = "ÐžÑ‚ÐºÑ€Ñ‹Ñ‚ÑŒ Ð¿Ð°Ð¿ÐºÑƒ ÑÐºÐ°Ð½Ð¾Ð²";
            folderButton.Location = new Point(30, 228);
            folderButton.Size = new Size(175, 30);
            folderButton.Click += OpenFolder;
            Controls.Add(folderButton);

            Label note = new Label();
            note.Text = "Mx310_Evgenium_scanner â€¢ Ñ†Ð²ÐµÑ‚Ð½Ð¾Ð¹ PNG â€¢ A4";
            note.AutoSize = true;
            note.ForeColor = Color.DimGray;
            note.Location = new Point(340, 236);
            Controls.Add(note);
        }

        private async void ScanClicked(object sender, EventArgs e)
        {
            scanButton.Enabled = false;
            resolution.Enabled = false;
            progress.Value = 0;
            string logPath = null;
            try
            {
                int dpi = resolution.SelectedIndex == 0 ? 75 : (resolution.SelectedIndex == 1 ? 150 : 300);
                string pictures = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
                string outputRoot = Path.Combine(pictures, "MX310 Scans");
                Directory.CreateDirectory(outputRoot);
                string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
                string output = Path.Combine(outputRoot, "MX310-" + stamp + ".png");
                string logRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MX310-Native", "logs");
                Directory.CreateDirectory(logRoot);
                logPath = Path.Combine(logRoot, "scan-" + stamp + ".log");

                string result = await Task.Run(delegate
                {
                    using (StreamWriter writer = new StreamWriter(logPath, false, new UTF8Encoding(true)))
                    {
                        Action<string> logger = delegate(string text)
                        {
                            lock (writer)
                            {
                                writer.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff") + " " + text);
                                writer.Flush();
                            }
                        };
                        Action<string, int> reporter = delegate(string text, int percent)
                        {
                            BeginInvoke((MethodInvoker)delegate
                            {
                                status.Text = text;
                                progress.Value = Math.Max(0, Math.Min(100, percent));
                            });
                        };
                        logger("Mx310_Evgenium_scanner native scan");
                        using (LibUsbTransport transport = new LibUsbTransport(logger))
                        {
                            PixmaMx310 scanner = new PixmaMx310(transport, logger, reporter);
                            return scanner.ScanFlatbed(dpi, output);
                        }
                    }
                });

                lastOutput = result;
                status.Text = "Ð“Ð¾Ñ‚Ð¾Ð²Ð¾: " + result;
                progress.Value = 100;
                Process.Start("explorer.exe", "/select,\"" + result + "\"");
                MessageBox.Show("Ð¡ÐºÐ°Ð½Ð¸Ñ€Ð¾Ð²Ð°Ð½Ð¸Ðµ Ð·Ð°Ð²ÐµÑ€ÑˆÐµÐ½Ð¾.\r\n\r\n" + result,
                    "Canon MX310", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                status.Text = "ÐžÑˆÐ¸Ð±ÐºÐ°. ÐžÐºÐ½Ð¾ Ð¾ÑÑ‚Ð°Ð²Ð»ÐµÐ½Ð¾ Ð¾Ñ‚ÐºÑ€Ñ‹Ñ‚Ñ‹Ð¼; Ð¿Ð¾Ð´Ñ€Ð¾Ð±Ð½Ð¾ÑÑ‚Ð¸ Ð·Ð°Ð¿Ð¸ÑÐ°Ð½Ñ‹ Ð² Ð¶ÑƒÑ€Ð½Ð°Ð».";
                MessageBox.Show(ex.ToString() + (logPath == null ? "" : "\r\n\r\nÐ–ÑƒÑ€Ð½Ð°Ð»: " + logPath),
                    "Canon MX310 ARM64 â€” Ð¾ÑˆÐ¸Ð±ÐºÐ° ÑÐºÐ°Ð½Ð¸Ñ€Ð¾Ð²Ð°Ð½Ð¸Ñ", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally
            {
                scanButton.Enabled = true;
                resolution.Enabled = true;
            }
        }

        private void OpenFolder(object sender, EventArgs e)
        {
            string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "MX310 Scans");
            Directory.CreateDirectory(folder);
            if (lastOutput != null && File.Exists(lastOutput))
                Process.Start("explorer.exe", "/select,\"" + lastOutput + "\"");
            else
                Process.Start("explorer.exe", folder);
        }
    }
}

