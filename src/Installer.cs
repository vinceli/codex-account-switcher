using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

namespace CodexAccountSwitcherInstaller
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            bool silent = false;
            foreach (var arg in args)
            {
                if (arg.Equals("/s", StringComparison.OrdinalIgnoreCase) ||
                    arg.Equals("/silent", StringComparison.OrdinalIgnoreCase))
                {
                    silent = true;
                }
            }

            if (silent)
            {
                try
                {
                    string defaultDir = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        @"Programs\CodexAccountSwitcher"
                    );
                    InstallerLogic.PerformInstall(defaultDir, true, true, false);
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine("Silent install error: " + ex.Message);
                    Environment.Exit(1);
                }
                return;
            }

            Application.Run(new InstallerForm());
        }
    }

    internal static class InstallerLogic
    {
        public static void PerformInstall(string destDir, bool createDesktop, bool createStartMenu, bool launchAfter)
        {
            if (!Directory.Exists(destDir))
            {
                Directory.CreateDirectory(destDir);
            }

            // 解壓縮內嵌的 payload.zip
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream resStream = asm.GetManifestResourceStream("payload.zip"))
            {
                if (resStream == null)
                {
                    throw new InvalidOperationException("安裝檔內部資源缺失 (payload.zip not found)。");
                }

                using (ZipArchive archive = new ZipArchive(resStream, ZipArchiveMode.Read))
                {
                    foreach (ZipArchiveEntry entry in archive.Entries)
                    {
                        if (string.IsNullOrEmpty(entry.Name)) continue; // 目錄條目
                        string fullPath = Path.Combine(destDir, entry.FullName);
                        string dir = Path.GetDirectoryName(fullPath);
                        if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                        entry.ExtractToFile(fullPath, true);
                    }
                }
            }

            string targetExe = Path.Combine(destDir, "CodexAccountSwitcher.exe");

            // 建立捷徑 (透過 WScript.Shell)
            Type shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType != null)
            {
                dynamic shell = Activator.CreateInstance(shellType);
                if (createDesktop)
                {
                    try
                    {
                        string desk = Environment.GetFolderPath(Environment.SpecialFolder.Desktop);
                        dynamic link = shell.CreateShortcut(Path.Combine(desk, "Codex 帳號切換.lnk"));
                        link.TargetPath = targetExe;
                        link.WorkingDirectory = destDir;
                        link.Description = "Codex 帳號切換工具";
                        link.Save();
                    }
                    catch { }
                }

                if (createStartMenu)
                {
                    try
                    {
                        string sm = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs");
                        dynamic link = shell.CreateShortcut(Path.Combine(sm, "Codex 帳號切換.lnk"));
                        link.TargetPath = targetExe;
                        link.WorkingDirectory = destDir;
                        link.Description = "Codex 帳號切換工具";
                        link.Save();
                    }
                    catch { }
                }
            }

            // 寫入 Windows 應用程式清單 (新增或移除程式)
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexAccountSwitcher"))
                {
                    if (key != null)
                    {
                        key.SetValue("DisplayName", "Codex 帳號切換工具");
                        key.SetValue("DisplayVersion", "1.0.0");
                        key.SetValue("Publisher", "Codex Tools");
                        key.SetValue("InstallLocation", destDir);
                        key.SetValue("UninstallString", "\"" + Path.Combine(destDir, "Uninstall.bat") + "\"");
                        key.SetValue("DisplayIcon", targetExe);
                    }
                }
            }
            catch { }

            if (launchAfter && File.Exists(targetExe))
            {
                try
                {
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = targetExe,
                        WorkingDirectory = destDir
                    });
                }
                catch { }
            }
        }
    }

    internal class InstallerForm : Form
    {
        private TextBox txtPath;
        private CheckBox chkDesktop;
        private CheckBox chkStartMenu;
        private CheckBox chkLaunch;
        private Button btnInstall;
        private Button btnCancel;
        private Label lblStatus;

        public InstallerForm()
        {
            InitializeComponent();
        }

        private void InitializeComponent()
        {
            this.Text = "Codex 帳號切換工具 - 安裝精靈";
            this.Size = new Size(540, 380);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.FormBorderStyle = FormBorderStyle.FixedDialog;
            this.MaximizeBox = false;
            this.Font = new Font("Microsoft JhengHei UI", 9.5F, FontStyle.Regular, GraphicsUnit.Point);

            // 頂部橫幅
            Panel topPanel = new Panel
            {
                Dock = DockStyle.Top,
                Height = 70,
                BackColor = Color.FromArgb(245, 247, 250)
            };

            Label lblTitle = new Label
            {
                Text = "安裝 Codex 帳號切換工具 (v1.0.0)",
                Font = new Font("Microsoft JhengHei UI", 12F, FontStyle.Bold),
                ForeColor = Color.FromArgb(30, 41, 59),
                Location = new Point(20, 15),
                AutoSize = true
            };

            Label lblSubtitle = new Label
            {
                Text = "安全、無痛且不互相撤銷憑證的 Windows 多帳號切換器",
                ForeColor = Color.FromArgb(100, 116, 139),
                Location = new Point(22, 42),
                AutoSize = true
            };

            topPanel.Controls.Add(lblTitle);
            topPanel.Controls.Add(lblSubtitle);
            this.Controls.Add(topPanel);

            // 安裝路徑區
            Label lblPathDesc = new Label
            {
                Text = "目標安裝資料夾（建議保留預設，不需管理員權限）：",
                Location = new Point(20, 95),
                AutoSize = true
            };
            this.Controls.Add(lblPathDesc);

            string defaultDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                @"Programs\CodexAccountSwitcher"
            );

            txtPath = new TextBox
            {
                Text = defaultDir,
                Location = new Point(23, 122),
                Width = 385
            };
            this.Controls.Add(txtPath);

            Button btnBrowse = new Button
            {
                Text = "瀏覽...",
                Location = new Point(418, 120),
                Width = 85,
                Height = 28
            };
            btnBrowse.Click += (s, e) =>
            {
                using (FolderBrowserDialog fbd = new FolderBrowserDialog())
                {
                    fbd.SelectedPath = txtPath.Text;
                    if (fbd.ShowDialog(this) == DialogResult.OK)
                    {
                        txtPath.Text = fbd.SelectedPath;
                    }
                }
            };
            this.Controls.Add(btnBrowse);

            // 選項區
            chkDesktop = new CheckBox
            {
                Text = "在桌面建立捷徑",
                Checked = true,
                Location = new Point(25, 170),
                AutoSize = true
            };
            this.Controls.Add(chkDesktop);

            chkStartMenu = new CheckBox
            {
                Text = "在開始功能表建立捷徑",
                Checked = true,
                Location = new Point(25, 200),
                AutoSize = true
            };
            this.Controls.Add(chkStartMenu);

            chkLaunch = new CheckBox
            {
                Text = "安裝完成後立即啟動 Codex 帳號切換器",
                Checked = true,
                Location = new Point(25, 230),
                AutoSize = true
            };
            this.Controls.Add(chkLaunch);

            // 狀態與按鈕
            lblStatus = new Label
            {
                Text = "點擊「開始安裝」以繼續...",
                ForeColor = Color.FromArgb(71, 85, 105),
                Location = new Point(20, 290),
                AutoSize = true
            };
            this.Controls.Add(lblStatus);

            btnInstall = new Button
            {
                Text = "開始安裝",
                Location = new Point(310, 285),
                Width = 95,
                Height = 32,
                BackColor = Color.FromArgb(37, 99, 235),
                ForeColor = Color.White,
                FlatStyle = FlatStyle.Flat
            };
            btnInstall.FlatAppearance.BorderSize = 0;
            btnInstall.Click += BtnInstall_Click;
            this.Controls.Add(btnInstall);

            btnCancel = new Button
            {
                Text = "取消",
                Location = new Point(415, 285),
                Width = 90,
                Height = 32
            };
            btnCancel.Click += (s, e) => { this.Close(); };
            this.Controls.Add(btnCancel);
        }

        private void BtnInstall_Click(object sender, EventArgs e)
        {
            string targetDir = txtPath.Text.Trim();
            if (string.IsNullOrEmpty(targetDir))
            {
                MessageBox.Show(this, "請輸入有效的安裝路徑。", "提示", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            try
            {
                btnInstall.Enabled = false;
                btnCancel.Enabled = false;
                lblStatus.Text = "正在部署檔案與建立系統捷徑...";
                Application.DoEvents();

                InstallerLogic.PerformInstall(
                    targetDir,
                    chkDesktop.Checked,
                    chkStartMenu.Checked,
                    chkLaunch.Checked
                );

                lblStatus.Text = "安裝完成！";
                MessageBox.Show(this, "Codex 帳號切換工具已成功安裝！\n\n您可隨時由桌面捷徑啟動。", "安裝成功", MessageBoxButtons.OK, MessageBoxIcon.Information);
                this.Close();
            }
            catch (Exception ex)
            {
                btnInstall.Enabled = true;
                btnCancel.Enabled = true;
                lblStatus.Text = "安裝過程發生錯誤。";
                MessageBox.Show(this, "安裝失敗: " + ex.Message, "錯誤", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }
}
