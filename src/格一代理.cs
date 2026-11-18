// GeYiProxy / 格一代理 - native WinForms tray application, v1.1.0
// Target: .NET Framework 4.0 / C# 4 / Win7 SP1, Win10, Win11 (AnyCPU, GUI subsystem)
// Source is UTF-8; build.ps1 converts non-ASCII to \uXXXX and injects version.txt.
//
// Command line:
//   (no args)             first run -> install silently, then this process becomes the tray
//   /install [/silent]    install only, then launch tray child
//   /uninstall [/silent]  full uninstall
//   /tray                 tray UI only (single instance)
//   /config               open the configuration window
//   /setmode Auto|On|Off  one-shot switch
//   /switch <id>          switch active proxy server (address + CA + bypass)
//   /servers              list configured servers
//   /status               show status
//   /version              write version_output.txt and show it
//   /checkupdate          force an update manifest check
//   /approve              manually approve a pending update
//   /upgrade [/silent]    internal: replace the installed exe from a verified download
//
// Red lines (kept from the validated 1.0 package):
//   * proxy_mode.ps1 is the ONLY writer of proxy registry state for automatic decisions.
//   * The tray is UI + manual commands; the PT1M Guard short task owns fail-open.
//   * Scheduled tasks keep the wscript GUI host (zero CMD/PowerShell windows).
//   * 10.0.50.199:15888 stays a MITM forward proxy (Internet_Assistant, one PIN/host).
//   * Upgrade is canary-first: PHASE=canary only allows CANARY_HOSTS (mingjiu-pc).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("格一代理")]
[assembly: AssemblyDescription("格一集团 上网助手代理客户端 - 多服务器 / 托盘配置 / 自动升级")]
[assembly: AssemblyProduct("格一代理")]
[assembly: AssemblyCompany("格一集团技控部")]
[assembly: AssemblyCopyright("Copyright 2026 格一集团技控部")]
[assembly: AssemblyVersion("__VER4__")]
[assembly: AssemblyFileVersion("__VER4__")]
[assembly: ComVisible(false)]

namespace GeYiProxy
{
    internal static class L
    {
        public const string App = "格一代理";
        public const string Publisher = "格一集团技控部";
        public const string Ver = "__VER__";
        public const string Build = "__BUILD__";
        public const string CfgVer = "__CFGVER__";
        public const string Mutex = @"Global\GeYiProxy_Tray_v1";
        public const string ConfigMutex = @"Global\GeYiProxy_Config_v1";
        public const string UninstallKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\GeYiProxy";
        public const string RunKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
        public const string RunName = "ProxyClientTray";
        public const string TaskCA = "ProxyClient_CARefresh";
        public const string TaskGuard = "ProxyClient_TrayGuard";
        public const string Folder = "ProxyClient";
        public const string DefaultBypass = "10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>;*.qq.com;*.qpic.cn;*.qlogo.cn;*.gtimg.cn;*.gtimg.com;*.wechat.com;*.weixin.com;*.tencent.com";
    }

    internal static class Cfg
    {
        public const string RegInet = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings";

        private static string _dir;
        public static string Dir
        {
            get
            {
                if (_dir == null)
                {
                    string la = Environment.GetEnvironmentVariable("LOCALAPPDATA");
                    if (string.IsNullOrEmpty(la)) la = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                    if (string.IsNullOrEmpty(la)) la = Path.GetTempPath();
                    _dir = Path.Combine(la, L.Folder);
                }
                return _dir;
            }
        }

        public static string Exe { get { return Path.Combine(Dir, L.App + ".exe"); } }
        public static string Self { get { return Application.ExecutablePath; } }
        public static string P(string n) { return Path.Combine(Dir, n); }
        public static string ModePs { get { return P("proxy_mode.ps1"); } }
        public static string CaPs { get { return P("ca_refresh.ps1"); } }
        public static string ServersFile { get { return P("servers.conf"); } }
        public static string ActiveFile { get { return P("active_server.txt"); } }
        public static string VersionFile { get { return P("app_version.txt"); } }
        public static string UpdateConf { get { return P("update.conf"); } }
        public static string UpdateCheckPs { get { return P("update_check.ps1"); } }
        public static string UpdateState { get { return P("update_state.txt"); } }
        public static string PendingFlag { get { return P("pending_update.flag"); } }
        public static string UpgradeLog { get { return P("upgrade.log"); } }
        public static string StateFile { get { return P("proxy_state.txt"); } }
        public static string ModeFile { get { return P("proxy_mode.txt"); } }
        public static string CaState { get { return P("ca_state.txt"); } }
        public static string Manifest { get { return P("install_manifest.txt"); } }
        public static string AppLog { get { return P("app.log"); } }
        public static string DisableFlag { get { return P("tray_disabled.flag"); } }
        public static string ExitFlag { get { return P("tray_exit.flag"); } }
        public static string SimFlag { get { return P("simulate_unreachable.flag"); } }
        public static string AutoSwitchFile { get { return P("auto_switch.txt"); } }
        public static string NodeHealthFile { get { return P("node_health.txt"); } }
        // 1.3.0: "退出程序" writes this flag; the TrayGuard must NOT relaunch
        // the tray while it exists. Removed by "启动托盘" / after reboot.
        public static string QuitFlag { get { return P("tray_quit.flag"); } }
        // 1.3.0: random rotation settings. File holds "MINUTES=<n>" and
        // "ON=1|0". Default ON, 30 minutes.
        public static string RotateFile { get { return P("auto_rotate.txt"); } }
        // 1.3.0: bookkeeping for the last rotation (timestamp + node id)
        public static string RotateStateFile { get { return P("rotate_state.txt"); } }
        public static string UninstallLog { get { return Path.Combine(Path.GetTempPath(), "GeYiProxy_uninstall.log"); } }
        public static string ExeNameNoExt { get { return Path.GetFileNameWithoutExtension(Exe); } }
    }

    internal class Srv
    {
        public string Id, Name, Host, CaMode, CaUrl, CaCert, PubKey, Bypass, Enabled;
        public int Port;
        public string Address { get { return "http://" + Host + ":" + Port; } }
        public string Line()
        {
            return string.Join("|", new string[] {
                Id, Name, Host, Port.ToString(), CaMode, CaUrl, CaCert, PubKey, Bypass, Enabled });
        }
    }

    internal static class ServerStore
    {
        public static Srv Default()
        {
            return new Srv {
                Id = "199", Name = "代理节点 199 (10.0.50.199)", Host = "10.0.50.199", Port = 15888,
                CaMode = "signed", CaUrl = "http://10.0.50.199:15889/ca.txt", CaCert = "",
                PubKey = "ca_sign_pub.xml", Bypass = L.DefaultBypass, Enabled = "1" };
        }

        public static List<Srv> Load()
        {
            List<Srv> list = new List<Srv>();
            try
            {
                if (File.Exists(Cfg.ServersFile))
                    foreach (string raw in File.ReadAllLines(Cfg.ServersFile, Encoding.UTF8))
                    {
                        string line = raw.Trim();
                        if (line.Length == 0 || line.StartsWith("#")) continue;
                        string[] f = line.Split('|');
                        if (f.Length < 10) continue;
                        int port;
                        if (!int.TryParse(f[3], out port) || port <= 0 || port > 65535) continue;
                        if (f[0].Length == 0 || f[2].Length == 0) continue;
                        string mode = f[4];
                        if (mode != "signed" && mode != "static" && mode != "none") mode = "signed";
                        list.Add(new Srv {
                            Id = f[0], Name = f[1], Host = f[2], Port = port, CaMode = mode,
                            CaUrl = f[5], CaCert = f[6], PubKey = f[7], Bypass = f[8], Enabled = f[9] });
                    }
            }
            catch (Exception e) { Util.Log("servers.conf load: " + e.Message); }
            if (list.Count == 0) list.Add(Default());
            return list;
        }

        public static string ActiveId()
        {
            string id = "";
            try { if (File.Exists(Cfg.ActiveFile)) id = File.ReadAllText(Cfg.ActiveFile, Encoding.UTF8).Trim(); }
            catch { }
            List<Srv> list = Load();
            foreach (Srv s in list) if (s.Id == id) return id;
            foreach (Srv s in list) if (s.Enabled == "1") return s.Id;
            return list[0].Id;
        }

        public static Srv Active()
        {
            string id = ActiveId();
            foreach (Srv s in Load()) if (s.Id == id) return s;
            return Load()[0];
        }

        public static void Save(List<Srv> list, string activeId)
        {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("# GeYiProxy servers.conf  (UTF-8, pipe separated, CFGVER=" + L.CfgVer + ")");
            sb.AppendLine("# id|name|host|port|caMode|caUrl|caCert|pubKey|bypass|enabled");
            sb.AppendLine("# caMode: signed (RSA-SHA256 signed /ca.txt, same as 199) | static (local DER) | none (no MITM)");
            foreach (Srv s in list) sb.AppendLine(s.Line());
            Util.WriteUtf8(Cfg.ServersFile, sb.ToString());
            if (!string.IsNullOrEmpty(activeId))
                File.WriteAllText(Cfg.ActiveFile, activeId, Encoding.UTF8);
        }
    }

    internal static class Util
    {
        [DllImport("wininet.dll", SetLastError = true)]
        private static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int length);
        [DllImport("user32.dll")]
        private static extern bool DestroyIcon(IntPtr hIcon);

        public static void RefreshWinInet()
        {
            try { InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0); InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0); }
            catch { }
        }

        public static void Log(string msg)
        {
            try
            {
                Directory.CreateDirectory(Cfg.Dir);
                File.AppendAllText(Cfg.AppLog,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [" + Process.GetCurrentProcess().Id + "] " + msg + "\r\n",
                    Encoding.UTF8);
            }
            catch { }
        }

        // UTF-8 with BOM: Get-Content / Notepad / PowerShell 5.1 display Chinese
        // text correctly, while every reader in this app uses Encoding.UTF8 and
        // transparently strips the BOM.
        public static void WriteUtf8(string path, string text)
        {
            File.WriteAllText(path, text, new UTF8Encoding(true));
        }

        public static string RunHidden(string file, string args, int timeoutMs)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = file;
                psi.Arguments = args;
                psi.WorkingDirectory = Cfg.Dir;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                Process p = Process.Start(psi);
                string so = p.StandardOutput.ReadToEnd();
                string se = p.StandardError.ReadToEnd();
                if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } }
                return (so + se).Trim();
            }
            catch (Exception e) { return "ERR:" + e.Message; }
        }

        public static string PS(string scriptArgs)
        {
            string ps = Path.Combine(Environment.GetEnvironmentVariable("WINDIR"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(ps)) ps = "powershell.exe";
            return RunHidden(ps, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden " + scriptArgs, 90000);
        }

        public static string TaskCtl(string action)
        {
            return PS("-File \"" + Cfg.P("task_ctl.ps1") + "\" -Action " + action);
        }

        public static bool IsAdmin()
        {
            try
            {
                System.Security.Principal.WindowsIdentity id = System.Security.Principal.WindowsIdentity.GetCurrent();
                return new System.Security.Principal.WindowsPrincipal(id).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
            }
            catch { return false; }
        }

        public static Dictionary<string, string> ReadKv(string path)
        {
            Dictionary<string, string> h = new Dictionary<string, string>();
            try
            {
                foreach (string raw in File.ReadAllLines(path, Encoding.UTF8))
                {
                    string line = raw.Trim();
                    if (line.Length == 0 || line.StartsWith("#")) continue;
                    int i = line.IndexOf('=');
                    if (i > 0) h[line.Substring(0, i).Trim()] = line.Substring(i + 1).Trim();
                }
            }
            catch { }
            return h;
        }

        public static Dictionary<string, string> ReadState() { return ReadKv(Cfg.StateFile); }

        // Compare two dotted version strings. Returns <0, 0 or >0.
        // Numeric comparison, so "1.10.0" > "1.9.0" (not lexical).
        public static int CompareVer(string a, string b)
        {
            string[] xa = (a ?? "").Split('.');
            string[] xb = (b ?? "").Split('.');
            int n = Math.Max(xa.Length, xb.Length);
            for (int i = 0; i < n; i++)
            {
                int va = 0, vb = 0;
                if (i < xa.Length) int.TryParse(xa[i].Trim(), out va);
                if (i < xb.Length) int.TryParse(xb[i].Trim(), out vb);
                if (va != vb) return va < vb ? -1 : 1;
            }
            return 0;
        }

        public static int StateAgeSeconds()
        {
            Dictionary<string, string> st = ReadState();
            if (!st.ContainsKey("TS")) return 9999;
            DateTime t;
            if (!DateTime.TryParseExact(st["TS"], "yyyy-MM-dd HH:mm:ss",
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None, out t)) return 9999;
            return (int)Math.Round((DateTime.Now - t).TotalSeconds);
        }

        public static string Sha256Hex(string path)
        {
            using (SHA256Managed sha = new SHA256Managed())
            {
                StringBuilder sb = new StringBuilder();
                foreach (byte b in sha.ComputeHash(File.ReadAllBytes(path))) sb.Append(b.ToString("X2"));
                return sb.ToString();
            }
        }

        public static Icon BrandIcon(int size)
        {
            try
            {
                byte[] raw = Res.Get("geyi.ico");
                if (raw != null)
                    using (MemoryStream ms = new MemoryStream(raw)) return new Icon(ms, size, size);
            }
            catch { }
            return MakePlainIcon(Color.FromArgb(255, 198, 37, 32));
        }

        public static Image BrandBanner()
        {
            try
            {
                byte[] raw = Res.Get("geyi_logo.png");
                if (raw != null) return Image.FromStream(new MemoryStream(raw));
            }
            catch { }
            return null;
        }

        public static Icon MakePlainIcon(Color c)
        {
            Bitmap bmp = new Bitmap(16, 16, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.Transparent);
                using (SolidBrush br = new SolidBrush(c)) g.FillEllipse(br, 1, 1, 14, 14);
                using (Pen pen = new Pen(Color.White)) g.DrawEllipse(pen, 1, 1, 14, 14);
            }
            return IconFromBitmap(bmp);
        }

        private static Icon IconFromBitmap(Bitmap bmp)
        {
            IntPtr h = bmp.GetHicon();
            Icon ic = (Icon)Icon.FromHandle(h).Clone();
            DestroyIcon(h);
            bmp.Dispose();
            return ic;
        }

        // Branded 16x16 mark + a status dot in the lower-right corner.
        public static Icon StatusIcon(string color)
        {
            Color c = Color.FromArgb(255, 140, 140, 140);
            if (color == "green") c = Color.FromArgb(255, 30, 160, 70);
            else if (color == "yellow") c = Color.FromArgb(255, 235, 170, 0);
            else if (color == "red") c = Color.FromArgb(255, 215, 50, 50);
            Bitmap bmp = new Bitmap(16, 16, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.Transparent);
                try { using (Icon b = BrandIcon(16)) g.DrawIcon(b, 0, 0); }
                catch { using (SolidBrush br = new SolidBrush(Color.White)) g.FillRectangle(br, 0, 0, 16, 16); }
                g.FillEllipse(Brushes.White, 9, 9, 7, 7);
                using (SolidBrush br = new SolidBrush(c)) g.FillEllipse(br, 10, 10, 5, 5);
            }
            return IconFromBitmap(bmp);
        }

        public static bool CreateShortcut(string lnkPath, string target, string args, string desc)
        {
            try
            {
                Type t = Type.GetTypeFromProgID("WScript.Shell");
                if (t == null) return false;
                object shell = Activator.CreateInstance(t);
                object sc = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnkPath });
                Type st = sc.GetType();
                st.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { target });
                st.InvokeMember("Arguments", BindingFlags.SetProperty, null, sc, new object[] { args });
                st.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc, new object[] { Cfg.Dir });
                st.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc, new object[] { target + ",0" });
                st.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { desc });
                st.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
                return true;
            }
            catch (Exception e) { Util.Log("shortcut failed: " + e.Message); return false; }
        }
    }

    internal static class Installer
    {
        public static bool IsInstalled()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(L.UninstallKey)) { if (k == null) return false; }
                return File.Exists(Cfg.Exe);
            }
            catch { return false; }
        }

        // User-owned configuration must survive an upgrade. Everything else is
        // refreshed from the embedded payload of the new exe.
        private static bool IsUserFile(string n)
        {
            if (n == "servers.conf" || n == "active_server.txt" || n == "update.conf") return true;
            if (n.StartsWith("ca_sign_pub_") && n.EndsWith(".xml")) return true;
            if (n.StartsWith("ca_") && n.EndsWith(".cer")) return true;
            return false;
        }

        // An older tray holds a lock on the installed exe. On a manual
        // overwrite install (double-click a newer build) File.Copy would fail
        // and leave the OLD exe installed with the NEW payload -> version skew.
        // Always stop other tray instances before replacing the file.
        private static void StopOtherTrays()
        {
            try
            {
                int selfPid = Process.GetCurrentProcess().Id;
                foreach (Process p in Process.GetProcessesByName(Cfg.ExeNameNoExt))
                {
                    if (p.Id == selfPid) continue;
                    try { p.Kill(); Util.Log("stopped old tray pid=" + p.Id); } catch { }
                }
                Thread.Sleep(400);
            }
            catch (Exception e) { Util.Log("stop old tray: " + e.Message); }
        }

        public static void Run(bool silent, bool launchChild)
        {
            Util.Log("INSTALL begin v" + L.Ver + "/" + L.Build + " admin=" + Util.IsAdmin());
            try
            {
                StopOtherTrays();
                Directory.CreateDirectory(Cfg.Dir);

                // 1) payload (preserve user configuration)
                string[] names = Res.Names();
                foreach (string n in names)
                {
                    string dst = Cfg.P(n);
                    if (File.Exists(dst) && IsUserFile(n)) { Util.Log("keep user config " + n); continue; }
                    try { File.WriteAllBytes(dst, Res.Get(n)); }
                    catch (Exception e) { Util.Log("payload " + n + " FAILED " + e.Message); }
                }
                StringBuilder mf = new StringBuilder();
                foreach (string n in names) mf.Append(n).Append("\r\n");
                Util.WriteUtf8(Cfg.Manifest, mf.ToString());

                // 2) self copy
                try { if (string.Compare(Cfg.Self, Cfg.Exe, true) != 0) File.Copy(Cfg.Self, Cfg.Exe, true); }
                catch (Exception e) { Util.Log("self copy: " + e.Message); }

                // 3) clear legacy PS tray leftovers
                foreach (string f in new string[] { "tray_disabled.flag", "tray_exit.flag", "proxy_tray.ps1", "proxy_tray.vbs" })
                    try { File.Delete(Cfg.P(f)); } catch { }

                // 4) proxy + revocation + CA (all derived from the ACTIVE server)
                ApplyProxy(true);
                SetRevocation(true);
                InstallCA();

                // 5) tasks / startup / ARP / shortcuts
                Util.Log("tasks: " + Util.TaskCtl("install"));
                RegisterRun();
                RegisterUninstall();
                RegisterShortcuts();

                // 6) initial decision through the single writer
                if (!File.Exists(Cfg.ModeFile)) File.WriteAllText(Cfg.ModeFile, "Auto", Encoding.ASCII);
                Util.Log("initial mode: " + Util.PS("-File \"" + Cfg.ModePs + "\" -Mode Auto -Reason install"));

                // 7) immediate CA sync + Guard heartbeat
                Util.Log("task run: " + Util.TaskCtl("run"));

                if (launchChild) LaunchTrayChild();
                Util.Log("INSTALL done");
                if (!silent) TrayApp.Balloon("格一代理 已安装", "版本 " + L.Ver + "；右键托盘图标可切换服务器、打开配置或卸载。");
            }
            catch (Exception e) { Util.Log("INSTALL FAILED: " + e); }
        }

        public static void ApplyProxy(bool on)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(Cfg.RegInet, true))
                {
                    if (k == null) return;
                    if (on)
                    {
                        Srv s = ServerStore.Active();
                        string bypass = string.IsNullOrEmpty(s.Bypass) ? L.DefaultBypass : s.Bypass;
                        k.SetValue("ProxyEnable", 1, RegistryValueKind.DWord);
                        k.SetValue("ProxyServer", s.Address, RegistryValueKind.String);
                        k.SetValue("ProxyOverride", bypass, RegistryValueKind.String);
                        try { k.DeleteValue("AutoConfigURL", false); } catch { }
                    }
                    else
                    {
                        k.SetValue("ProxyEnable", 0, RegistryValueKind.DWord);
                        string[] vals = { "ProxyServer", "ProxyOverride", "AutoConfigURL" };
                        foreach (string v in vals) { try { k.DeleteValue(v, false); } catch { } }
                    }
                }
                Util.RefreshWinInet();
            }
            catch (Exception e) { Util.Log("ApplyProxy: " + e.Message); }
        }

        private static void SetRevocation(bool on)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(Cfg.RegInet, true))
                { if (k != null) k.SetValue("CertificateRevocation", 0, RegistryValueKind.DWord); }
            }
            catch { }
            try
            {
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(Cfg.RegInet, true))
                { if (k != null) k.SetValue("CertificateRevocation", 0, RegistryValueKind.DWord); }
            }
            catch { Util.Log("HKLM revocation skipped (needs admin)"); }
        }

        private static void ClearRevocation()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(Cfg.RegInet, true))
                { if (k != null) { try { k.DeleteValue("CertificateRevocation", false); } catch { } } }
            }
            catch { }
            try
            {
                using (RegistryKey k = Registry.LocalMachine.OpenSubKey(Cfg.RegInet, true))
                { if (k != null) { try { k.DeleteValue("CertificateRevocation", false); } catch { } } }
            }
            catch { }
        }

        private static void ImportCert(string file, string tag)
        {
            try
            {
                if (!File.Exists(file)) { Util.Log("CA bootstrap missing " + file); return; }
                X509Certificate2 cert = new X509Certificate2(File.ReadAllBytes(file));
                string thumb = cert.Thumbprint;
                StoreLocation[] locs = { StoreLocation.CurrentUser, StoreLocation.LocalMachine };
                foreach (StoreLocation loc in locs)
                {
                    try
                    {
                        X509Store store = new X509Store(StoreName.Root, loc);
                        store.Open(OpenFlags.ReadWrite);
                        List<X509Certificate2> kill = new List<X509Certificate2>();
                        bool present = false;
                        foreach (X509Certificate2 c in store.Certificates)
                        {
                            if (c.Subject.IndexOf("mitmproxy", StringComparison.OrdinalIgnoreCase) < 0) continue;
                            if (string.Compare(c.Thumbprint, thumb, true) == 0) present = true;
                            else kill.Add(c);
                        }
                        foreach (X509Certificate2 c in kill) { try { store.Remove(c); } catch { } PurgeCertReg(c.Thumbprint, loc); }
                        if (!present) store.Add(cert);
                        store.Close();
                        Util.Log("CA " + tag + " " + loc + " ok thumb=" + thumb + " removed=" + kill.Count);
                    }
                    catch (Exception e) { Util.Log("CA " + tag + " " + loc + " skipped: " + e.Message); }
                }
            }
            catch (Exception e) { Util.Log("CA " + tag + ": " + e.Message); }
        }

        private static void InstallCA()
        {
            Srv s = ServerStore.Active();
            if (s.CaMode == "none") { Util.Log("CA none for " + s.Id); return; }
            if (s.CaMode == "static")
            {
                if (!string.IsNullOrEmpty(s.CaCert)) ImportCert(Cfg.P(s.CaCert), "static/" + s.Id);
                return;
            }
            if (s.Id == "199") ImportCert(Cfg.P("internet_assistant_ca.cer"), "bootstrap/199");
            else Util.Log("signed CA: no bundled bootstrap for " + s.Id + ", ca_refresh will fetch " + s.CaUrl);
        }

        private static void PurgeCertReg(string thumb, StoreLocation loc)
        {
            string p = @"SOFTWARE\Microsoft\SystemCertificates\Root\Certificates\" + thumb;
            try
            {
                if (loc == StoreLocation.CurrentUser) Registry.CurrentUser.DeleteSubKeyTree(p);
                else Registry.LocalMachine.DeleteSubKeyTree(p);
            }
            catch { }
        }

        private static int CountVisibleCA()
        {
            Dictionary<string, int> seen = new Dictionary<string, int>();
            foreach (StoreLocation loc in new StoreLocation[] { StoreLocation.CurrentUser, StoreLocation.LocalMachine })
            {
                try
                {
                    X509Store st = new X509Store(StoreName.Root, loc);
                    st.Open(OpenFlags.ReadOnly);
                    foreach (X509Certificate2 c in st.Certificates)
                        if (c.Subject.IndexOf("mitmproxy", StringComparison.OrdinalIgnoreCase) >= 0) seen[c.Thumbprint] = 1;
                    st.Close();
                }
                catch { }
            }
            return seen.Count;
        }

        private static int RemoveAllCA()
        {
            StoreLocation[] locs = { StoreLocation.CurrentUser, StoreLocation.LocalMachine };
            foreach (StoreLocation loc in locs)
            {
                try
                {
                    X509Store store = new X509Store(StoreName.Root, loc);
                    store.Open(OpenFlags.ReadWrite);
                    List<X509Certificate2> kill = new List<X509Certificate2>();
                    foreach (X509Certificate2 c in store.Certificates)
                        if (c.Subject.IndexOf("mitmproxy", StringComparison.OrdinalIgnoreCase) >= 0) kill.Add(c);
                    foreach (X509Certificate2 c in kill) { try { store.Remove(c); } catch { } PurgeCertReg(c.Thumbprint, loc); }
                    store.Close();
                    Util.Log("CA removed " + loc + " count=" + kill.Count);
                }
                catch (Exception e) { Util.Log("CA remove " + loc + ": " + e.Message); }
            }
            int left = CountVisibleCA();
            if (left > 0) Util.Log("CA residual (machine-level, needs admin): " + left);
            return left;
        }

        private static void RegisterRun()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(L.RunKey, true))
                { if (k != null) k.SetValue(L.RunName, "\"" + Cfg.Exe + "\" /tray", RegistryValueKind.String); }
            }
            catch (Exception e) { Util.Log("RegisterRun: " + e.Message); }
        }

        private static void RegisterUninstall()
        {
            try
            {
                RegistryKey k = Registry.CurrentUser.CreateSubKey(L.UninstallKey);
                k.SetValue("DisplayName", L.App, RegistryValueKind.String);
                k.SetValue("DisplayVersion", L.Ver, RegistryValueKind.String);
                k.SetValue("Publisher", L.Publisher, RegistryValueKind.String);
                k.SetValue("DisplayIcon", Cfg.Exe + ",0", RegistryValueKind.String);
                k.SetValue("InstallLocation", Cfg.Dir, RegistryValueKind.String);
                k.SetValue("UninstallString", "\"" + Cfg.Exe + "\" /uninstall", RegistryValueKind.String);
                k.SetValue("QuietUninstallString", "\"" + Cfg.Exe + "\" /uninstall /silent", RegistryValueKind.String);
                k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                k.SetValue("EstimatedSize", 900, RegistryValueKind.DWord);
                k.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"), RegistryValueKind.String);
                k.Close();
            }
            catch (Exception e) { Util.Log("RegisterUninstall: " + e.Message); }
        }

        private static void RegisterShortcuts()
        {
            try
            {
                string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs", L.App);
                Directory.CreateDirectory(root);
                Util.CreateShortcut(Path.Combine(root, L.App + ".lnk"), Cfg.Exe, "/tray", "启动/显示 格一代理 托盘");
                Util.CreateShortcut(Path.Combine(root, "配置 " + L.App + ".lnk"), Cfg.Exe, "/config", "打开 格一代理 配置窗口");
                Util.CreateShortcut(Path.Combine(root, "卸载 " + L.App + ".lnk"), Cfg.Exe, "/uninstall", "卸载 格一代理");
                // Desktop shortcut (per-user, no UAC prompt)
                string desktop = Environment.GetFolderPath(Environment.SpecialFolder.Desktop);
                Util.CreateShortcut(Path.Combine(desktop, L.App + ".lnk"), Cfg.Exe, "/tray", "启动/显示 格一代理 托盘");
                Util.WriteUtf8(Cfg.P("shortcut_dir.txt"), root);
            }
            catch (Exception e) { Util.Log("RegisterShortcuts: " + e.Message); }
        }

        public static void LaunchTrayChild()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = Cfg.Exe;
                psi.Arguments = "/tray";
                psi.UseShellExecute = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                Process.Start(psi);
                Util.Log("tray child launched");
            }
            catch (Exception e)
            {
                Util.Log("tray child direct failed: " + e.Message);
                try { Process.Start("explorer.exe", "\"" + Cfg.Exe + "\" /tray"); Util.Log("tray child via explorer launched"); }
                catch (Exception e2) { Util.Log("tray child explorer failed: " + e2.Message); }
            }
        }

        private static void ULog(string s)
        {
            try { File.AppendAllText(Cfg.UninstallLog, DateTime.Now.ToString("HH:mm:ss") + " " + s + "\r\n", Encoding.UTF8); }
            catch { }
        }

        public static void Uninstall(bool silent)
        {
            int caVisible = 0;
            StringBuilder log = new StringBuilder();
            try { File.WriteAllText(Cfg.UninstallLog, "GeYiProxy uninstall " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\r\n", Encoding.UTF8); } catch { }
            ULog("start");
            try
            {
                try { log.AppendLine(Util.TaskCtl("delete")); } catch { }
                ULog("tasks removed");
                try { File.WriteAllText(Cfg.DisableFlag, "uninstall", Encoding.ASCII); } catch { }
                try { File.WriteAllText(Cfg.ExitFlag, "uninstall", Encoding.ASCII); } catch { }
                Thread.Sleep(1200);
                int selfPid = Process.GetCurrentProcess().Id;
                try
                {
                    foreach (Process p in Process.GetProcessesByName(Cfg.ExeNameNoExt))
                    {
                        if (p.Id == selfPid) continue;
                        try { p.Kill(); log.AppendLine("killed tray pid=" + p.Id); } catch { }
                    }
                }
                catch (Exception e) { log.AppendLine("tray stop: " + e.Message); }
                ULog("tray stopped");

                try
                {
                    using (RegistryKey k = Registry.CurrentUser.OpenSubKey(L.RunKey, true))
                    { if (k != null) k.DeleteValue(L.RunName, false); }
                }
                catch { }
                try { Registry.CurrentUser.DeleteSubKeyTree(L.UninstallKey); } catch { }
                try
                {
                    string sf = Cfg.P("shortcut_dir.txt");
                    if (File.Exists(sf))
                    {
                        string d = File.ReadAllText(sf).Trim();
                        if (d.Length > 0 && d.IndexOf(L.Folder, StringComparison.OrdinalIgnoreCase) < 0)
                            if (Directory.Exists(d)) Directory.Delete(d, true);
                    }
                }
                catch (Exception e) { log.AppendLine("shortcut cleanup: " + e.Message); }
                // Desktop shortcut cleanup (per-user)
                try
                {
                    string dsk = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Desktop), L.App + ".lnk");
                    if (File.Exists(dsk)) File.Delete(dsk);
                }
                catch (Exception e) { log.AppendLine("desktop shortcut cleanup: " + e.Message); }
                ULog("run/ARP/shortcut removed");

                ApplyProxy(false);
                ClearRevocation();
                try
                {
                    string[] vars = { "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy" };
                    using (RegistryKey k = Registry.CurrentUser.OpenSubKey("Environment", true))
                    { if (k != null) foreach (string v in vars) { try { k.DeleteValue(v, false); } catch { } } }
                }
                catch { }
                caVisible = RemoveAllCA();
                ULog("registry + CA cleaned; residual=" + caVisible);
                log.AppendLine("registry + CA cleaned; visible_mitmproxy_CA_left=" + caVisible);

                List<string> files = new List<string>();
                try
                {
                    if (File.Exists(Cfg.Manifest))
                        foreach (string s in File.ReadAllLines(Cfg.Manifest)) if (s.Trim().Length > 0) files.Add(s.Trim());
                }
                catch { }
                string[] extra = {
                    "proxy_mode.txt","proxy_state.txt","proxy_mode.log","app.log","ca_state.txt","ca_refresh.log",
                    "tray_probe.txt","tray_relaunch_ts.txt","tray_disabled.flag","tray_exit.flag",
                    "simulate_unreachable.flag","verify_result.txt","shortcut_dir.txt","install_manifest.txt",
                    "status.txt","ca_refresh.bat","格一代理.exe","servers.conf","active_server.txt",
                    "app_version.txt","update.conf","update_check.ps1","update_state.txt","update_last_check.txt",
                    "update.log","pending_update.flag","upgrade.log","geyi.ico","geyi_logo.png",
                    "version_output.txt","servers_output.txt","ca_sign_pub.xml"
                };
                foreach (string s in extra) if (!files.Contains(s)) files.Add(s);
                bool selfIsInstalledCopy = (string.Compare(Cfg.Self, Cfg.Exe, true) == 0);
                foreach (string f in files)
                {
                    if (selfIsInstalledCopy && string.Compare(f, L.App + ".exe", true) == 0) continue;
                    try { File.Delete(Cfg.P(f)); } catch { }
                }
                try { Directory.Delete(Cfg.P("downloads"), true); } catch { }
                ULog("payload deleted");

                try
                {
                    string qexe = "\"" + Cfg.Exe + "\"";
                    string qdir = "\"" + Cfg.Dir + "\"";
                    string cmd = "/c \"ping -n 3 127.0.0.1 >nul & del /f /q " + qexe + " & rmdir /s /q " + qdir + "\"";
                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = Path.Combine(Environment.GetEnvironmentVariable("WINDIR"), "System32", "cmd.exe");
                    psi.Arguments = cmd;
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    psi.WindowStyle = ProcessWindowStyle.Hidden;
                    Process.Start(psi);
                    log.AppendLine("delayed cleanup scheduled");
                }
                catch (Exception e) { log.AppendLine("delayed cleanup: " + e.Message); }
                ULog("delayed cleanup scheduled");
            }
            catch (Exception e) { ULog("FATAL " + e); log.AppendLine("FATAL " + e); }
            finally
            {
                try { File.AppendAllText(Cfg.UninstallLog, log.ToString(), Encoding.UTF8); } catch { }
                ULog("done");
            }
            if (!silent)
            {
                string msg = "格一代理 已卸载完成。\r\n\r\n代理、根证书、计划任务、启动项、服务器配置和升级组件均已清除，浏览器将恢复直连。";
                if (caVisible > 0)
                    msg += "\r\n\r\n注意：仍有 " + caVisible + " 张 mitmproxy 根证书残留（本机级，普通权限无法删除）。\r\n请以管理员身份再运行一次卸载，或执行：certutil -delstore Root <指纹>";
                msg += "\r\n\r\n日志：" + Cfg.UninstallLog;
                try { MessageBox.Show(msg, "格一代理 - 卸载", MessageBoxButtons.OK, MessageBoxIcon.Information); }
                catch { }
            }
        }
    }

        internal static class Updater
        {
        public static string Check(bool force, bool approve)
        {
            string args = "-File \"" + Cfg.UpdateCheckPs + "\"";
            if (force) args += " -Force";
            if (approve) args += " -Approve";
            return Util.PS(args);
        }

        public static Dictionary<string, string> State() { return Util.ReadKv(Cfg.UpdateState); }
        public static Dictionary<string, string> Pending() { return Util.ReadKv(Cfg.PendingFlag); }

        // Runs INSIDE the downloaded exe. Verifies the download again, stops the
        // old tray, replaces the installed exe, re-plays the installer (which keeps
        // user config), then launches the new tray.
        public static void RunUpgrade()
        {
            StringBuilder log = new StringBuilder();
            log.AppendLine("GeYiProxy upgrade " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            try
            {
                Dictionary<string, string> p = Pending();
                if (!p.ContainsKey("PATH") || !p.ContainsKey("SHA256"))
                { log.AppendLine("ABORT bad pending flag"); return; }
                string src = p["PATH"];
                string want = p["SHA256"].ToUpperInvariant();
                string ver = p.ContainsKey("VER") ? p["VER"] : "?";
                string build = p.ContainsKey("BUILD") ? p["BUILD"] : "?";
                if (!File.Exists(src)) { log.AppendLine("ABORT download missing " + src); return; }
                string got = Util.Sha256Hex(src);
                if (string.Compare(got, want, true) != 0)
                {
                    log.AppendLine("ABORT hash mismatch got=" + got + " want=" + want);
                    try { File.Delete(Cfg.PendingFlag); } catch { }
                    return;
                }
                if (p.ContainsKey("SIZE") && File.ReadAllBytes(src).Length.ToString() != p["SIZE"])
                { log.AppendLine("ABORT size mismatch"); return; }
                log.AppendLine("verified " + ver + "/" + build + " sha256=" + got);

                try { File.WriteAllText(Cfg.ExitFlag, "upgrade", Encoding.ASCII); } catch { }
                int selfPid = Process.GetCurrentProcess().Id;
                foreach (Process pr in Process.GetProcessesByName(Cfg.ExeNameNoExt))
                {
                    if (pr.Id == selfPid) continue;
                    try { pr.Kill(); log.AppendLine("stopped old tray pid=" + pr.Id); } catch { }
                }
                // Wait for the OS to release the exe handles. A killed process
                // keeps its image section mapped for a short while, so an
                // immediate Copy() throws UnauthorizedAccessException.
                int waited = 0;
                while (waited < 10000)
                {
                    bool stillThere = false;
                    try
                    {
                        foreach (Process pr in Process.GetProcessesByName(Cfg.ExeNameNoExt))
                        {
                            if (pr.Id == selfPid) continue;
                            stillThere = true; break;
                        }
                    }
                    catch { }
                    if (!stillThere) break;
                    Thread.Sleep(300); waited += 300;
                }
                log.AppendLine("waited " + waited + "ms for exe handle release");

                // Replace via rename-exchange. Copying ONTO the running exe is
                // not possible (sharing violation); copying to a temp name and
                // renaming works even while the old image is mapped.
                string tmpExe = Cfg.Exe + ".new";
                string oldExe = Cfg.Exe + ".old";
                bool replaced = false;
                for (int attempt = 1; attempt <= 5 && !replaced; attempt++)
                {
                    try
                    {
                        try { if (File.Exists(tmpExe)) File.Delete(tmpExe); } catch { }
                        try { if (File.Exists(oldExe)) File.Delete(oldExe); } catch { }
                        File.Copy(src, tmpExe, true);
                        // rename current -> .old, then .new -> current
                        if (File.Exists(Cfg.Exe))
                        {
                            try { File.Move(Cfg.Exe, oldExe); } catch { }
                        }
                        try
                        {
                            File.Move(tmpExe, Cfg.Exe);
                            replaced = true;
                            log.AppendLine("installed exe replaced (attempt " + attempt + ", rename-exchange)");
                        }
                        catch
                        {
                            // rename failed -> restore
                            try { if (!File.Exists(Cfg.Exe) && File.Exists(oldExe)) File.Move(oldExe, Cfg.Exe); } catch { }
                            throw;
                        }
                    }
                    catch (Exception re)
                    {
                        log.AppendLine("replace attempt " + attempt + " failed: " + re.Message);
                        Thread.Sleep(1500);
                    }
                }
                if (!replaced)
                {
                    log.AppendLine("FATAL could not replace exe after 5 attempts");
                    // CRITICAL: clear the pending flag. Otherwise every tray
                    // start re-triggers the upgrade and the tray enters an
                    // endless restart loop (the user sees "it exits when I
                    // click anything").
                    try { File.Delete(Cfg.PendingFlag); } catch { }
                    try { File.Delete(Cfg.ExitFlag); } catch { }
                    Util.WriteUtf8(Cfg.UpdateState,
                        "STATUS=install-failed\r\nCUR_VER=" + L.Ver + "\r\nCUR_BUILD=" + L.Build +
                        "\r\nNEW_VER=" + ver + "\r\nNEW_BUILD=" + build + "\r\nPHASE=canary\r\nALLOWED=1\r\n" +
                        "ERROR=exe replace failed after 5 attempts (file locked)\r\n" +
                        "TS=" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\r\n");
                    Installer.LaunchTrayChild();
                    return;
                }
                // best-effort cleanup of the backup copy
                try { if (File.Exists(oldExe)) File.Delete(oldExe); } catch { }
                Installer.Run(true, false);
                log.AppendLine("installer replayed (user config preserved)");

                try { File.Delete(Cfg.PendingFlag); } catch { }
                try { File.Delete(Cfg.ExitFlag); } catch { }
                Util.WriteUtf8(Cfg.UpdateState,
                    "STATUS=installed\r\nCUR_VER=" + ver + "\r\nCUR_BUILD=" + build +
                    "\r\nNEW_VER=" + ver + "\r\nNEW_BUILD=" + build + "\r\nPHASE=canary\r\nALLOWED=1\r\n" +
                    "NOTE=升级完成\r\nTS=" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\r\n");
                Installer.LaunchTrayChild();
                log.AppendLine("DONE new tray launched");
            }
            catch (Exception e)
            {
                log.AppendLine("FATAL " + e);
                // SAFETY: never leave the pending flag behind on failure.
                // A leftover pending flag makes every tray start re-launch the
                // upgrade, which turns into an endless restart loop.
                try { File.Delete(Cfg.PendingFlag); } catch { }
                try { File.Delete(Cfg.ExitFlag); } catch { }
                try
                {
                    Util.WriteUtf8(Cfg.UpdateState,
                        "STATUS=install-failed\r\nCUR_VER=" + L.Ver + "\r\nCUR_BUILD=" + L.Build +
                        "\r\nPHASE=canary\r\nALLOWED=1\r\nERROR=" +
                        e.GetType().Name + ": " + e.Message.Replace("\r", " ").Replace("\n", " ") +
                        "\r\nTS=" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\r\n");
                }
                catch { }
                // bring the tray back so the user still has a working program
                try { Installer.LaunchTrayChild(); } catch { }
            }
            finally
            {
                try { File.AppendAllText(Cfg.UpgradeLog, log.ToString(), Encoding.UTF8); } catch { }
                Util.Log("UPGRADE " + log.ToString().Replace("\r\n", " | "));
            }
        }
    }

    // ------------------------------------------------------------------
    // Multi-node health probe. Each configured server exposes GET :15889/health
    // returning JSON with status / forwardingOk / caDrift. Probes hit the
    // intranet IP directly (never through the system proxy) with a short timeout.
    // ------------------------------------------------------------------
    internal static class HealthProbe
    {
        // probe result: 0=offline, 1=online(OK), 2=degraded(status not OK / caDrift)
        public static int Probe(Srv s)
        {
            try
            {
                string url = "http://" + s.Host + ":15889/health";
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                req.Timeout = 2500;
                req.ReadWriteTimeout = 2500;
                req.Proxy = null;                 // never go through the proxy we are managing
                req.CachePolicy = new System.Net.Cache.RequestCachePolicy(System.Net.Cache.RequestCacheLevel.NoCacheNoStore);
                string json = "";
                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                {
                    if (resp.StatusCode != HttpStatusCode.OK) return 0;
                    using (StreamReader sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                        json = sr.ReadToEnd();
                }
                if (json.Length == 0) return 0;
                string low = json.ToLowerInvariant();
                bool ok = low.Contains("\"status\":\"ok\"") || low.Contains("\"status\": \"ok\"");
                bool fwd = !low.Contains("\"forwardingok\":false") && !low.Contains("\"forwardingok\": false");
                bool drift = low.Contains("\"cadrift\":true") || low.Contains("\"cadrift\": true");
                if (ok && fwd && !drift) return 1;
                return 2;
            }
            catch { return 0; }
        }

        public static string Mark(int r)
        {
            if (r == 1) return "● ";   // online
            if (r == 2) return "△ ";   // degraded
            return "○ ";              // offline
        }
    }

    internal static class Actions
    {
        public static void SetMode(string mode, string reason)
        {
            if (mode != "Auto" && mode != "On" && mode != "Off") return;
            Util.Log("SetMode " + mode + " by " + reason);
            Util.PS("-File \"" + Cfg.ModePs + "\" -Mode " + mode + " -Reason " + reason);
            Util.TaskCtl("run");
        }

        // Switch gateway: address/port, bypass list, CA trust root and fail-open
        // probe all follow servers.conf + active_server.txt.
        public static void SwitchServer(string id, string reason)
        {
            List<Srv> list = ServerStore.Load();
            Srv target = null;
            foreach (Srv s in list) if (s.Id == id) target = s;
            if (target == null) { Util.Log("SwitchServer unknown id=" + id); return; }
            Util.Log("SwitchServer " + ServerStore.ActiveId() + " -> " + id + " by " + reason);
            File.WriteAllText(Cfg.ActiveFile, id, Encoding.UTF8);
            try { File.Delete(Cfg.CaState); } catch { }
            // Set-ProxyMode writes the proxy AND refreshes proxy_state.txt synchronously.
            // Do NOT fire the Guard task here: a Guard started during the previous
            // switch may still be probing with the old server and would overwrite
            // this decision. The PT1M Guard picks up the new config on its own.
            Util.PS("-File \"" + Cfg.ModePs + "\" -Mode Auto -Reason switch-" + id);
            Util.PS("-File \"" + Cfg.CaPs + "\"");
            Util.Log("SwitchServer done -> " + target.Address + " caMode=" + target.CaMode);
        }

        // Auto-switch: enabled flag stored in auto_switch.txt ("1"/"0", default 0=off).
        public static bool AutoSwitchEnabled()
        {
            try { if (File.Exists(Cfg.AutoSwitchFile)) return File.ReadAllText(Cfg.AutoSwitchFile).Trim() == "1"; }
            catch { }
            return false;
        }
        public static void SetAutoSwitch(bool on)
        {
            try { File.WriteAllText(Cfg.AutoSwitchFile, on ? "1" : "0", Encoding.UTF8); } catch { }
            Util.Log("AutoSwitch set to " + on);
        }

        // Probe every enabled server; returns id->result map.
        public static Dictionary<string, int> ProbeAll()
        {
            Dictionary<string, int> m = new Dictionary<string, int>();
            foreach (Srv s in ServerStore.Load())
            {
                if (s.Enabled != "1") continue;
                m[s.Id] = HealthProbe.Probe(s);
            }
            return m;
        }

        // If active node is offline/degraded for consecutive ticks, switch to best healthy node.
        // Tracks consecutive bad ticks in memory (TrayApp passes the counter by ref via file state).
        public static string AutoSwitchTick(Dictionary<string, int> results, ref int badTicks,
                                             int threshold, out string reason)
        {
            reason = "";
            string act = ServerStore.ActiveId();
            int cur = 0;
            if (!results.TryGetValue(act, out cur)) cur = 0;
            if (cur == 1) { badTicks = 0; return ""; }   // current healthy -> reset
            badTicks++;
            if (badTicks < threshold) return "";
            // pick first healthy node that is not the current one
            string best = "";
            foreach (Srv s in ServerStore.Load())
            {
                if (s.Enabled != "1" || s.Id == act) continue;
                int r = 0; if (results.TryGetValue(s.Id, out r) && r == 1) { best = s.Id; break; }
            }
            if (best.Length == 0) { reason = "无健康节点可切换"; return ""; }
            reason = "当前节点连续 " + badTicks + " 次异常，自动切到 " + best;
            badTicks = 0;
            SwitchServer(best, "auto-switch");
            return best;
        }

        // ------------------------------------------------------------------
        // 1.3.0  Random rotation
        //
        // Purpose: never keep using the SAME overseas exit IP forever. The
        // mobile CPE can have that IP rate-limited/blocked, which would kill
        // overseas access for the whole company. Rotating spreads traffic
        // across the 5 nodes and keeps every node's IP "fresh".
        //
        // Rules (deliberately conservative):
        //   1) Rotate only to a node that is currently HEALTHY (result == 1).
        //   2) Never rotate to the same node we are on now.
        //   3) Only rotate when the machine is IDLE for overseas traffic -
        //      an active browsing session must not be interrupted mid-flight.
        //      "Idle" = no TCP connection to any proxy port has been seen
        //      for the configured quiet window.
        //   4) The target is chosen RANDOMLY among healthy nodes (not the
        //      first one), so traffic does not always land on the same node.
        // ------------------------------------------------------------------

        public static bool RotateEnabled()
        {
            try
            {
                if (!File.Exists(Cfg.RotateFile)) return true;   // default ON
                Dictionary<string, string> kv = Util.ReadKv(Cfg.RotateFile);
                if (!kv.ContainsKey("ON")) return true;
                return kv["ON"].Trim() != "0";
            }
            catch { return true; }
        }

        // Rotation interval in minutes. Default 30. Clamped to 5..720.
        public static int RotateMinutes()
        {
            try
            {
                if (!File.Exists(Cfg.RotateFile)) return 30;
                Dictionary<string, string> kv = Util.ReadKv(Cfg.RotateFile);
                int m = 30;
                if (kv.ContainsKey("MINUTES")) int.TryParse(kv["MINUTES"].Trim(), out m);
                if (m < 5) m = 5;
                if (m > 720) m = 720;
                return m;
            }
            catch { return 30; }
        }

        public static void SetRotate(bool on, int minutes)
        {
            try
            {
                if (minutes < 5) minutes = 5;
                if (minutes > 720) minutes = 720;
                File.WriteAllText(Cfg.RotateFile,
                    "ON=" + (on ? "1" : "0") + "\r\nMINUTES=" + minutes + "\r\n",
                    Encoding.UTF8);
                Util.Log("Rotate set on=" + on + " minutes=" + minutes);
            }
            catch (Exception e) { Util.Log("SetRotate failed: " + e.Message); }
        }

        // Timestamp + node id of the last rotation.
        private static DateTime LastRotateTime()
        {
            try
            {
                if (!File.Exists(Cfg.RotateStateFile)) return DateTime.MinValue;
                Dictionary<string, string> kv = Util.ReadKv(Cfg.RotateStateFile);
                DateTime t;
                if (kv.ContainsKey("TS") &&
                    DateTime.TryParseExact(kv["TS"].Trim(), "yyyy-MM-dd HH:mm:ss",
                        System.Globalization.CultureInfo.InvariantCulture,
                        System.Globalization.DateTimeStyles.None, out t)) return t;
            }
            catch { }
            return DateTime.MinValue;
        }

        private static void SaveRotateState(string nodeId)
        {
            try
            {
                File.WriteAllText(Cfg.RotateStateFile,
                    "TS=" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\r\nNODE=" + nodeId + "\r\n",
                    Encoding.UTF8);
            }
            catch { }
        }

        // Reset the rotation clock so a fresh install does not rotate instantly.
        public static void InitRotateClock()
        {
            if (!File.Exists(Cfg.RotateStateFile)) SaveRotateState(ServerStore.ActiveId());
        }

        // Quiet-window detection: is the user currently using the proxy?
        // Counts established TCP connections whose remote port is the proxy
        // port of ANY configured node. Browsers keep such sockets alive for a
        // while, so a short quiet window (default 60s) is a good "not busy" signal.
        public static bool ProxyBusy(out int connCount)
        {
            connCount = 0;
            try
            {
                List<int> ports = new List<int>();
                foreach (Srv s in ServerStore.Load()) if (s.Enabled == "1") ports.Add(s.Port);
                if (ports.Count == 0) return false;
                int n = 0;
                System.Net.NetworkInformation.IPGlobalProperties g =
                    System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties();
                System.Net.NetworkInformation.TcpConnectionInformation[] conns =
                    g.GetActiveTcpConnections();
                foreach (System.Net.NetworkInformation.TcpConnectionInformation c in conns)
                {
                    if (c.State != System.Net.NetworkInformation.TcpState.Established) continue;
                    System.Net.IPEndPoint ep = c.RemoteEndPoint as System.Net.IPEndPoint;
                    if (ep == null) continue;
                    if (ports.Contains(ep.Port)) n++;
                }
                connCount = n;
                return n > 0;
            }
            catch { return false; }
        }

        // Decide + perform a rotation if it is due.
        // Returns the new node id ("" = no rotation performed).
        public static string RotateTick(Dictionary<string, int> results, int quietSeconds, out string reason)
        {
            reason = "";
            if (!RotateEnabled()) return "";
            int intervalMin = RotateMinutes();
            DateTime last = LastRotateTime();
            if (last == DateTime.MinValue) { SaveRotateState(ServerStore.ActiveId()); return ""; }
            double dueMin = (DateTime.Now - last).TotalMinutes;
            if (dueMin < intervalMin) return "";

            string act = ServerStore.ActiveId();

            // 1) busy check - never interrupt an active overseas session
            int conns = 0;
            bool busy = ProxyBusy(out conns);
            if (busy)
            {
                reason = "轮换暂缓：仍有 " + conns + " 条代理连接在使用中";
                return "";
            }

            // 2) collect healthy candidates
            List<string> cands = new List<string>();
            foreach (Srv s in ServerStore.Load())
            {
                if (s.Enabled != "1") continue;
                int r = 0;
                if (results.TryGetValue(s.Id, out r) && r == 1) cands.Add(s.Id);
            }
            if (cands.Count == 0) { reason = "轮换暂缓：暂无健康节点"; return ""; }
            if (cands.Count == 1 && cands[0] == act)
            {
                // only one healthy node and it is the current one: nothing to do
                SaveRotateState(act);
                reason = "";
                return "";
            }

            // 3) pick RANDOMLY among candidates (exclude current)
            List<string> pool = new List<string>();
            foreach (string id in cands) if (id != act) pool.Add(id);
            if (pool.Count == 0) { SaveRotateState(act); return ""; }
            Random rnd = new Random();
            string pick = pool[rnd.Next(pool.Count)];

            Srv target = null;
            foreach (Srv s in ServerStore.Load()) if (s.Id == pick) target = s;
            if (target == null) return "";

            reason = "已连续使用 " + act + " 约 " + Math.Round(dueMin) + " 分钟，随机轮换到 " + pick + "（" + target.Name + "）";
            SwitchServer(pick, "auto-rotate");
            SaveRotateState(pick);
            return pick;
        }

        // ------------------------------------------------------------------
        // 1.3.0  Real exit
        //
        // "退出托盘" (old) only closed the UI - the TrayGuard task relaunched
        // it within 5 minutes, so the user could never actually stop it.
        // "退出程序" must stop EVERYTHING: tray process, the guard task that
        // would revive it, and the run-at-login entry. It writes a persistent
        // quit flag so the guard script knows this was intentional.
        // ------------------------------------------------------------------
        public static void ExitProgram()
        {
            Util.Log("ExitProgram: full shutdown requested");
            try { File.WriteAllText(Cfg.QuitFlag, "quit", Encoding.ASCII); } catch { }

            // 1) stop the guard tasks so nothing relaunches the tray
            try { Util.TaskCtl("delete"); } catch { }
            try
            {
                Util.PS("-File \"" + Cfg.P("task_ctl.ps1") + "\" -Action delete");
            }
            catch { }

            // 2) remove the run-at-login entry
            try
            {
                using (RegistryKey rk = Registry.CurrentUser.OpenSubKey(L.RunKey, true))
                { if (rk != null) rk.DeleteValue(L.RunName, false); }
            }
            catch { }

            // 3) ask the tray to quit (it deletes the flag it owns and exits)
            try { File.WriteAllText(Cfg.ExitFlag, "quit", Encoding.ASCII); } catch { }
        }

        // Bring the program back after "退出程序".
        public static void ResumeProgram()
        {
            try { File.Delete(Cfg.QuitFlag); } catch { }
            try { File.Delete(Cfg.ExitFlag); } catch { }
            Util.TaskCtl("install");
            Util.Log("ResumeProgram: guard tasks reinstalled");
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = Cfg.Exe;
                psi.Arguments = "/tray";
                psi.UseShellExecute = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                Process.Start(psi);
            }
            catch (Exception e) { Util.Log("ResumeProgram launch failed: " + e.Message); }
        }

        public static bool IsQuitted()
        {
            try { return File.Exists(Cfg.QuitFlag); }
            catch { return false; }
        }

        public static string VersionText()
        {
            Dictionary<string, string> v = Util.ReadKv(Cfg.VersionFile);
            string ver = v.ContainsKey("VER") ? v["VER"] : L.Ver;
            string build = v.ContainsKey("BUILD") ? v["BUILD"] : L.Build;
            return ver + " (BUILD " + build + ")";
        }

        public static string Status()
        {
            Dictionary<string, string> st = Util.ReadState();
            Srv s = ServerStore.Active();
            string mode = File.Exists(Cfg.ModeFile) ? File.ReadAllText(Cfg.ModeFile).Trim() : "Auto";
            string pe = "?";
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(Cfg.RegInet))
                { if (k != null) pe = Convert.ToString(k.GetValue("ProxyEnable", "?")); }
            }
            catch { }
            Dictionary<string, string> u = Updater.State();
            StringBuilder nodes = new StringBuilder();
            Dictionary<string, int> hmap = new Dictionary<string, int>();
            string healthDetail = "";
            try
            {
                if (File.Exists(Cfg.NodeHealthFile))
                    foreach (string ln in File.ReadAllLines(Cfg.NodeHealthFile, Encoding.UTF8))
                    {
                        if (ln.StartsWith("TS=")) { healthDetail = " (" + ln.Substring(3) + ")"; continue; }
                        foreach (string part in ln.Split(';'))
                        {
                            string[] kv = part.Split('=');
                            int rv;
                            if (kv.Length == 2 && int.TryParse(kv[1], out rv)) hmap[kv[0]] = rv;
                        }
                    }
            }
            catch { }
            foreach (Srv node in ServerStore.Load())
            {
                if (node.Enabled != "1") continue;
                int r = 0; if (hmap.ContainsKey(node.Id)) r = hmap[node.Id];
                nodes.Append("  " + HealthProbe.Mark(r) + node.Id + "  " + node.Name + "  " + node.Address + "\r\n");
            }
            return L.App + " " + VersionText() + "\r\n" +
                   "节点列表" + healthDetail + ":\r\n" + nodes.ToString() +
                   "自动切换: " + (AutoSwitchEnabled() ? "开" : "关") + "\r\n" +
                   "随机轮换: " + (RotateEnabled() ? "开（每 " + RotateMinutes() + " 分钟，空闲时切换）" : "关") + "\r\n" +
                   "安装状态: " + (Installer.IsInstalled() ? "已安装" : "未安装") + "\r\n" +
                   "当前服务器: " + s.Name + "  [" + s.Id + "]  " + s.Address + "\r\n" +
                   "CA 模式: " + s.CaMode + "  " + (s.CaMode == "signed" ? s.CaUrl : s.CaCert) + "\r\n" +
                   "模式: " + mode + "\r\n" +
                   "系统代理: ProxyEnable=" + pe + "\r\n" +
                   "网关: " + (st.ContainsKey("GATEWAY") ? st["GATEWAY"] : "未知") + "\r\n" +
                   "托盘颜色: " + (st.ContainsKey("COLOR") ? st["COLOR"] : "未知") + "\r\n" +
                   "在线监测心跳: " + Util.StateAgeSeconds() + " 秒前\r\n" +
                   "升级状态: " + (u.ContainsKey("STATUS") ? u["STATUS"] : "未检查") + "\r\n" +
                   "安装目录: " + Cfg.Dir;
        }

        public static void OpenConfig()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = Cfg.Exe;
                psi.Arguments = "/config";
                psi.UseShellExecute = true;
                psi.WindowStyle = ProcessWindowStyle.Normal;
                Process.Start(psi);
                Util.Log("config window launched");
            }
            catch (Exception e)
            {
                Util.Log("config window direct failed: " + e.Message);
                try { Process.Start("explorer.exe", "\"" + Cfg.Exe + "\" /config"); } catch { }
            }
        }
    }

    // ------------------------------------------------------------------
    // Configuration window: server CRUD, CA per server, mode, upgrade, about
    // ------------------------------------------------------------------
    internal class ConfigForm : Form
    {
        private ListBox _list;
        private List<Srv> _servers;
        private int _index = -1;
        private TextBox _name, _host, _port, _caUrl, _pubKey, _caCert, _bypass;
        private ComboBox _caMode;
        private TabControl _tabs;
        private Label _status, _upgradeInfo, _about;
        private TextBox _updateUrl;
        private CheckBox _autoUpdate;
        private NumericUpDown _interval;
        private RadioButton _rbAuto, _rbOn, _rbOff;
        private Button _btnInstallUpdate;
        private bool _loading;

        public ConfigForm()
        {
            Text = L.App + " - 配置中心  v" + L.Ver;
            try { Icon = Util.BrandIcon(32); } catch { }
            StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(880, 650);
            MinimumSize = new Size(880, 650);
            MaximizeBox = false;
            Font = new Font("Microsoft YaHei", 9F);

            PictureBox banner = new PictureBox();
            banner.Location = new Point(12, 10);
            banner.Size = new Size(270, 93);
            banner.SizeMode = PictureBoxSizeMode.Zoom;
            try { Image im = Util.BrandBanner(); if (im != null) banner.Image = im; } catch { }
            Controls.Add(banner);

            Label ver = new Label();
            ver.Location = new Point(300, 18);
            ver.Size = new Size(550, 60);
            ver.Text = "格一集团 · 上网代理客户端\r\n版本 " + Actions.VersionText() + "   |   配置格式 CFGVER=" + L.CfgVer + "   |   当前服务器: " + ServerStore.Active().Name;
            ver.Font = new Font("Microsoft YaHei", 10F, FontStyle.Bold);
            Controls.Add(ver);

            _tabs = new TabControl();
            _tabs.Location = new Point(12, 108);
            _tabs.Size = new Size(840, 460);
            Controls.Add(_tabs);

            BuildServersTab();
            BuildRunTab();
            BuildUpgradeTab();
            BuildAboutTab();

            Button close = new Button();
            close.Text = "关闭";
            close.Location = new Point(752, 578);
            close.Size = new Size(100, 30);
            close.Click += delegate { Close(); };
            Controls.Add(close);

            Button logBtn = new Button();
            logBtn.Text = "打开日志目录";
            logBtn.Location = new Point(630, 578);
            logBtn.Size = new Size(112, 30);
            logBtn.Click += delegate { try { Process.Start("explorer.exe", Cfg.Dir); } catch { } };
            Controls.Add(logBtn);

            LoadServers();
            LoadRun();
            LoadUpgrade();
        }

        private Label Lb(string text, int x, int y)
        {
            Label l = new Label();
            l.Text = text; l.Location = new Point(x, y); l.Size = new Size(110, 22);
            l.TextAlign = ContentAlignment.MiddleRight;
            return l;
        }

        private void BuildServersTab()
        {
            TabPage tp = new TabPage("代理服务器");
            _tabs.TabPages.Add(tp);

            _list = new ListBox();
            _list.Location = new Point(14, 14);
            _list.Size = new Size(210, 350);
            _list.SelectedIndexChanged += delegate { if (!_loading) { SyncFromFields(); ShowServer(_list.SelectedIndex); } };
            tp.Controls.Add(_list);

            Button add = new Button(); add.Text = "新增"; add.Location = new Point(14, 372); add.Size = new Size(64, 28);
            add.Click += delegate { AddServer(); }; tp.Controls.Add(add);
            Button copy = new Button(); copy.Text = "复制"; copy.Location = new Point(86, 372); copy.Size = new Size(64, 28);
            copy.Click += delegate { CopyServer(); }; tp.Controls.Add(copy);
            Button del = new Button(); del.Text = "删除"; del.Location = new Point(158, 372); del.Size = new Size(66, 28);
            del.Click += delegate { DeleteServer(); }; tp.Controls.Add(del);

            int x = 240, w = 560;
            int y = 16;
            tp.Controls.Add(Lb("名称", x, y));
            _name = new TextBox(); _name.Location = new Point(x + 116, y); _name.Size = new Size(w - 116, 24); tp.Controls.Add(_name);
            y += 30;
            tp.Controls.Add(Lb("代理主机", x, y));
            _host = new TextBox(); _host.Location = new Point(x + 116, y); _host.Size = new Size(230, 24); tp.Controls.Add(_host);
            tp.Controls.Add(Lb("端口", x + 360, y));
            _port = new TextBox(); _port.Location = new Point(x + 476, y); _port.Size = new Size(80, 24); tp.Controls.Add(_port);
            y += 30;
            tp.Controls.Add(Lb("CA 模式", x, y));
            _caMode = new ComboBox(); _caMode.DropDownStyle = ComboBoxStyle.DropDownList;
            _caMode.Items.AddRange(new object[] { "signed (验签分发, 与199一致)", "static (本地证书)", "none (不装CA)" });
            _caMode.Location = new Point(x + 116, y); _caMode.Size = new Size(230, 24);
            _caMode.SelectedIndexChanged += delegate { UpdateCaFields(); };
            tp.Controls.Add(_caMode);
            y += 30;
            tp.Controls.Add(Lb("CA 分发地址", x, y));
            _caUrl = new TextBox(); _caUrl.Location = new Point(x + 116, y); _caUrl.Size = new Size(w - 116, 24); tp.Controls.Add(_caUrl);
            y += 30;
            tp.Controls.Add(Lb("验签公钥文件", x, y));
            _pubKey = new TextBox(); _pubKey.Location = new Point(x + 116, y); _pubKey.Size = new Size(300, 24); tp.Controls.Add(_pubKey);
            Button pickKey = new Button(); pickKey.Text = "导入..."; pickKey.Location = new Point(x + 424, y - 1); pickKey.Size = new Size(76, 26);
            pickKey.Click += delegate { ImportFile("XML 公钥|*.xml", "ca_sign_pub_", ".xml", _pubKey); }; tp.Controls.Add(pickKey);
            y += 30;
            tp.Controls.Add(Lb("本地证书文件", x, y));
            _caCert = new TextBox(); _caCert.Location = new Point(x + 116, y); _caCert.Size = new Size(300, 24); tp.Controls.Add(_caCert);
            Button pickCert = new Button(); pickCert.Text = "导入..."; pickCert.Location = new Point(x + 424, y - 1); pickCert.Size = new Size(76, 26);
            pickCert.Click += delegate { ImportFile("DER 证书|*.cer;*.crt", "ca_", ".cer", _caCert); }; tp.Controls.Add(pickCert);
            y += 30;
            tp.Controls.Add(Lb("直连例外", x, y));
            _bypass = new TextBox(); _bypass.Multiline = true; _bypass.ScrollBars = ScrollBars.Vertical;
            _bypass.Location = new Point(x + 116, y); _bypass.Size = new Size(w - 116, 92); tp.Controls.Add(_bypass);
            Button defBypass = new Button(); defBypass.Text = "恢复默认例外";
            defBypass.Location = new Point(x + 116, y + 96); defBypass.Size = new Size(120, 26);
            defBypass.Click += delegate { _bypass.Text = L.DefaultBypass; }; tp.Controls.Add(defBypass);
            y += 130;

            Button apply = new Button(); apply.Text = "设为当前服务器并应用";
            apply.Location = new Point(x + 116, y); apply.Size = new Size(190, 32);
            apply.Click += delegate { ApplyActive(); }; tp.Controls.Add(apply);
            Button save = new Button(); save.Text = "仅保存配置";
            save.Location = new Point(x + 316, y); save.Size = new Size(120, 32);
            save.Click += delegate { SyncFromFields(); ServerStore.Save(_servers, ServerStore.ActiveId()); MessageBox.Show("配置已保存。", L.App, MessageBoxButtons.OK, MessageBoxIcon.Information); };
            tp.Controls.Add(save);

            Label hint = new Label();
            hint.Location = new Point(x + 116, y + 40); hint.Size = new Size(w - 116, 44);
            hint.ForeColor = Color.FromArgb(90, 90, 90);
            hint.Text = "切换会依次执行：写 active → 改代理地址/例外 → 清旧 CA 并验签装新 CA → 触发在线监测心跳。\r\nsigned 模式每个服务器用自己的公钥验签 /ca.txt，CA 互不混用。";
            tp.Controls.Add(hint);
            UpdateCaFields();
        }

        private void BuildRunTab()
        {
            TabPage tp = new TabPage("运行与状态");
            _tabs.TabPages.Add(tp);
            GroupBox gb = new GroupBox();
            gb.Text = "运行模式"; gb.Location = new Point(16, 16); gb.Size = new Size(400, 130); tp.Controls.Add(gb);
            _rbAuto = new RadioButton(); _rbAuto.Text = "自动 (跟随在线监测 fail-open)"; _rbAuto.Location = new Point(18, 26); _rbAuto.Size = new Size(360, 24); gb.Controls.Add(_rbAuto);
            _rbOn = new RadioButton(); _rbOn.Text = "强制走当前代理"; _rbOn.Location = new Point(18, 56); _rbOn.Size = new Size(360, 24); gb.Controls.Add(_rbOn);
            _rbOff = new RadioButton(); _rbOff.Text = "强制直连 (回家/断网)"; _rbOff.Location = new Point(18, 86); _rbOff.Size = new Size(360, 24); gb.Controls.Add(_rbOff);
            Button apply = new Button(); apply.Text = "应用模式"; apply.Location = new Point(430, 30); apply.Size = new Size(110, 32);
            apply.Click += delegate {
                string m = _rbAuto.Checked ? "Auto" : (_rbOn.Checked ? "On" : "Off");
                Actions.SetMode(m, "config-window");
                MessageBox.Show("已应用模式: " + m, L.App, MessageBoxButtons.OK, MessageBoxIcon.Information);
                LoadRun();
            }; tp.Controls.Add(apply);
            Button refresh = new Button(); refresh.Text = "刷新状态"; refresh.Location = new Point(430, 72); refresh.Size = new Size(110, 32);
            refresh.Click += delegate { LoadRun(); }; tp.Controls.Add(refresh);
            Button detect = new Button(); detect.Text = "立即重新检测"; detect.Location = new Point(430, 114); detect.Size = new Size(110, 32);
            detect.Click += delegate { Actions.SetMode("Auto", "config-detect"); LoadRun(); }; tp.Controls.Add(detect);

            _status = new Label();
            _status.Location = new Point(16, 166); _status.Size = new Size(790, 240);
            _status.BorderStyle = BorderStyle.FixedSingle;
            _status.BackColor = Color.FromArgb(250, 251, 253);
            _status.Padding = new Padding(10);
            _status.Font = new Font("Consolas", 9.5F);
            tp.Controls.Add(_status);
        }

        private void BuildUpgradeTab()
        {
            TabPage tp = new TabPage("版本与升级");
            _tabs.TabPages.Add(tp);
            int y = 20, x = 20;
            tp.Controls.Add(Lb("清单地址", x, y));
            _updateUrl = new TextBox(); _updateUrl.Location = new Point(x + 116, y); _updateUrl.Size = new Size(640, 24); tp.Controls.Add(_updateUrl);
            y += 36;
            _autoUpdate = new CheckBox();
            _autoUpdate.Text = "允许自动安装 (仍受 PHASE=canary / CANARY_HOSTS 灰度限制)";
            _autoUpdate.Location = new Point(x + 116, y); _autoUpdate.Size = new Size(640, 24); tp.Controls.Add(_autoUpdate);
            y += 32;
            tp.Controls.Add(Lb("检查间隔(分)", x, y));
            _interval = new NumericUpDown(); _interval.Minimum = 5; _interval.Maximum = 1440;
            _interval.Location = new Point(x + 116, y); _interval.Size = new Size(90, 24); tp.Controls.Add(_interval);
            y += 40;

            Button save = new Button(); save.Text = "保存升级设置"; save.Location = new Point(x + 116, y); save.Size = new Size(130, 30);
            save.Click += delegate { SaveUpgrade(); MessageBox.Show("升级设置已保存。", L.App, MessageBoxButtons.OK, MessageBoxIcon.Information); };
            tp.Controls.Add(save);
            Button check = new Button(); check.Text = "立即检查更新"; check.Location = new Point(x + 256, y); check.Size = new Size(130, 30);
            check.Click += delegate { string r = Updater.Check(true, false); MessageBox.Show("检查结果: " + r, L.App, MessageBoxButtons.OK, MessageBoxIcon.Information); LoadUpgrade(); };
            tp.Controls.Add(check);
            _btnInstallUpdate = new Button(); _btnInstallUpdate.Text = "手动批准并安装更新";
            _btnInstallUpdate.Location = new Point(x + 396, y); _btnInstallUpdate.Size = new Size(170, 30);
            _btnInstallUpdate.Click += delegate {
                string r = Updater.Check(true, true);
                MessageBox.Show("已提交安装请求: " + r + "\r\n托盘将在数秒内完成替换并自动重启。", L.App, MessageBoxButtons.OK, MessageBoxIcon.Information);
                LoadUpgrade();
            };
            tp.Controls.Add(_btnInstallUpdate);
            y += 44;

            _upgradeInfo = new Label();
            _upgradeInfo.Location = new Point(x, y); _upgradeInfo.Size = new Size(790, 190);
            _upgradeInfo.BorderStyle = BorderStyle.FixedSingle;
            _upgradeInfo.BackColor = Color.FromArgb(250, 251, 253);
            _upgradeInfo.Padding = new Padding(10);
            _upgradeInfo.Font = new Font("Consolas", 9.5F);
            tp.Controls.Add(_upgradeInfo);

            Label note = new Label();
            note.Location = new Point(x, y + 198); note.Size = new Size(790, 44);
            note.ForeColor = Color.FromArgb(120, 60, 20);
            note.Text = "灰度铁律：清单 PHASE=canary 时仅 CANARY_HOSTS 列出的主机(默认 mingjiu-pc)可自动升级；\r\n金丝雀验证通过后把 PHASE 改为 all 才放行其余客户端。SHA256/SIZE 不符一律拒装。";
            tp.Controls.Add(note);
        }

        private void BuildAboutTab()
        {
            TabPage tp = new TabPage("关于");
            _tabs.TabPages.Add(tp);
            PictureBox pic = new PictureBox();
            pic.Location = new Point(24, 24); pic.Size = new Size(270, 93); pic.SizeMode = PictureBoxSizeMode.Zoom;
            try { Image im = Util.BrandBanner(); if (im != null) pic.Image = im; } catch { }
            tp.Controls.Add(pic);
            _about = new Label();
            _about.Location = new Point(24, 140); _about.Size = new Size(780, 250);
            _about.Font = new Font("Microsoft YaHei", 10F);
            _about.Text =
                "格一代理  " + L.Ver + "   BUILD " + L.Build + "   CFGVER " + L.CfgVer + "\r\n\r\n" +
                "格一集团技控部 · Windows 上网代理客户端\r\n" +
                ".NET Framework 4.0 / WinForms 原生单文件，Win7 SP1 / Win10 / Win11，x86/x64。\r\n\r\n" +
                "功能：多代理服务器切换（各自 CA 验签链）、托盘一键开关、fail-open 在线监测、\r\n" +
                "动态 CA 轮换自愈、配置窗口、版本控制与 canary 灰度自动升级。\r\n\r\n" +
                "红线：上网助手必须保留 MITM 与一机一 PIN；15900 管理通道不动；\r\n" +
                "proxy_mode.ps1 是代理注册表唯一写入点；升级必须先过 mingjiu-pc 金丝雀。";
            tp.Controls.Add(_about);
        }

        private void LoadServers()
        {
            _loading = true;
            _servers = ServerStore.Load();
            _list.Items.Clear();
            string act = ServerStore.ActiveId();
            foreach (Srv s in _servers) _list.Items.Add(s.Name + (s.Id == act ? "  [当前]" : ""));
            _index = -1;
            for (int i = 0; i < _servers.Count; i++) if (_servers[i].Id == act) { _index = i; break; }
            if (_index < 0) _index = 0;
            _list.SelectedIndex = _index;
            ShowServer(_index);
            _loading = false;
        }

        private void ShowServer(int i)
        {
            if (i < 0 || i >= _servers.Count) return;
            _index = i;
            Srv s = _servers[i];
            _name.Text = s.Name; _host.Text = s.Host; _port.Text = s.Port.ToString();
            _caUrl.Text = s.CaUrl; _pubKey.Text = s.PubKey; _caCert.Text = s.CaCert;
            _bypass.Text = string.IsNullOrEmpty(s.Bypass) ? L.DefaultBypass : s.Bypass;
            int mi = 0;
            if (s.CaMode == "static") mi = 1; else if (s.CaMode == "none") mi = 2;
            _caMode.SelectedIndex = mi;
            UpdateCaFields();
        }

        private void SyncFromFields()
        {
            if (_index < 0 || _index >= _servers.Count) return;
            Srv s = _servers[_index];
            int port = s.Port;
            int.TryParse(_port.Text.Trim(), out port);
            if (port <= 0 || port > 65535) port = s.Port;
            s.Name = _name.Text.Trim();
            s.Host = _host.Text.Trim();
            s.Port = port;
            s.CaMode = _caMode.SelectedIndex == 1 ? "static" : (_caMode.SelectedIndex == 2 ? "none" : "signed");
            s.CaUrl = _caUrl.Text.Trim();
            s.PubKey = _pubKey.Text.Trim();
            s.CaCert = _caCert.Text.Trim();
            s.Bypass = _bypass.Text.Trim();
            int sel = _list.SelectedIndex;
            if (sel < 0 || sel >= _list.Items.Count) return;  // guard: list not ready or no selection
            string act = ServerStore.ActiveId();
            _list.Items[sel] = s.Name + (s.Id == act ? "  [当前]" : "");
        }

        private void UpdateCaFields()
        {
            bool signed = (_caMode.SelectedIndex == 0);
            bool stat = (_caMode.SelectedIndex == 1);
            _caUrl.Enabled = signed; _pubKey.Enabled = signed;
            _caCert.Enabled = stat;
        }

        private void AddServer()
        {
            SyncFromFields();
            int n = 2;
            string id;
            do { id = "srv" + n; n++; } while (FindId(id));
            Srv s = new Srv {
                Id = id, Name = "新代理服务器", Host = "10.0.50.200", Port = 15888,
                CaMode = "signed", CaUrl = "http://10.0.50.200:15889/ca.txt", CaCert = "",
                PubKey = "ca_sign_pub_" + id + ".xml", Bypass = L.DefaultBypass, Enabled = "1" };
            _servers.Add(s);
            ServerStore.Save(_servers, ServerStore.ActiveId());
            LoadServers();
            _list.SelectedIndex = _servers.Count - 1;
            ShowServer(_servers.Count - 1);
            MessageBox.Show("已新增。请填写主机/端口/CA 地址，并导入该服务器的验签公钥，然后点『设为当前服务器并应用』。", L.App, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private bool FindId(string id) { foreach (Srv s in _servers) if (s.Id == id) return true; return false; }

        private void CopyServer()
        {
            SyncFromFields();
            if (_index < 0) return;
            Srv src = _servers[_index];
            int n = 2; string id;
            do { id = "srv" + n; n++; } while (FindId(id));
            Srv s = new Srv {
                Id = id, Name = src.Name + " (副本)", Host = src.Host, Port = src.Port,
                CaMode = src.CaMode, CaUrl = src.CaUrl, CaCert = src.CaCert,
                PubKey = "ca_sign_pub_" + id + ".xml", Bypass = src.Bypass, Enabled = "1" };
            _servers.Add(s);
            ServerStore.Save(_servers, ServerStore.ActiveId());
            LoadServers();
            _list.SelectedIndex = _servers.Count - 1;
            ShowServer(_servers.Count - 1);
        }

        private void DeleteServer()
        {
            if (_index < 0) return;
            if (_servers.Count <= 1) { MessageBox.Show("至少保留一台服务器。", L.App); return; }
            Srv s = _servers[_index];
            if (s.Id == ServerStore.ActiveId()) { MessageBox.Show("当前正在使用的服务器不能删除，请先切换到其他服务器。", L.App); return; }
            if (MessageBox.Show("删除服务器 [" + s.Name + "]？", L.App, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            _servers.RemoveAt(_index);
            ServerStore.Save(_servers, ServerStore.ActiveId());
            LoadServers();
        }

        private void ImportFile(string filter, string prefix, string ext, TextBox target)
        {
            using (OpenFileDialog d = new OpenFileDialog())
            {
                d.Filter = filter;
                if (d.ShowDialog() != DialogResult.OK) return;
                if (_index < 0) return;
                string dstName = prefix + _servers[_index].Id + ext;
                try
                {
                    File.Copy(d.FileName, Cfg.P(dstName), true);
                    target.Text = dstName;
                    SyncFromFields();
                    ServerStore.Save(_servers, ServerStore.ActiveId());
                    MessageBox.Show("已导入为 " + dstName, L.App, MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                catch (Exception e) { MessageBox.Show("导入失败: " + e.Message, L.App); }
            }
        }

        private void ApplyActive()
        {
            SyncFromFields();
            if (_index < 0) return;
            Srv s = _servers[_index];
            if (string.IsNullOrEmpty(s.Host)) { MessageBox.Show("代理主机不能为空。", L.App); return; }
            if (s.CaMode == "signed" && (string.IsNullOrEmpty(s.CaUrl) || string.IsNullOrEmpty(s.PubKey)))
            { MessageBox.Show("signed 模式必须填写 CA 分发地址与验签公钥文件。", L.App); return; }
            if (s.CaMode == "signed" && !File.Exists(Cfg.P(s.PubKey)))
            { MessageBox.Show("验签公钥文件不存在，请先点『导入...』。", L.App); return; }
            if (s.CaMode == "static" && (string.IsNullOrEmpty(s.CaCert) || !File.Exists(Cfg.P(s.CaCert))))
            { MessageBox.Show("static 模式必须导入本地证书。", L.App); return; }
            ServerStore.Save(_servers, s.Id);
            Actions.SwitchServer(s.Id, "config-window");
            LoadServers();
            LoadRun();
            MessageBox.Show("已切换到 [" + s.Name + "]\r\n" + s.Address + "\r\nCA 模式: " + s.CaMode +
                "\r\n\r\n代理与 CA 已刷新，在线监测心跳已触发。", L.App, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private void LoadRun()
        {
            string mode = File.Exists(Cfg.ModeFile) ? File.ReadAllText(Cfg.ModeFile).Trim() : "Auto";
            _rbAuto.Checked = (mode == "Auto"); _rbOn.Checked = (mode == "On"); _rbOff.Checked = (mode == "Off");
            _status.Text = Actions.Status();
            List<Srv> all = ServerStore.Load();
            _status.Text += "\r\n\r\n已配置服务器 " + all.Count + " 台:";
            foreach (Srv s in all)
                _status.Text += "\r\n  " + (s.Id == ServerStore.ActiveId() ? "* " : "  ") + s.Id + "  " + s.Name + "  " + s.Address + "  CA=" + s.CaMode;
        }

        private void SaveUpgrade()
        {
            Dictionary<string, string> c = Util.ReadKv(Cfg.UpdateConf);
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("# GeYiProxy update.conf - edited in config window");
            sb.AppendLine("UPDATE_URL=" + _updateUrl.Text.Trim());
            sb.AppendLine("AUTO_UPDATE=" + (_autoUpdate.Checked ? "1" : "0"));
            sb.AppendLine("CHECK_INTERVAL_MIN=" + _interval.Value.ToString());
            Util.WriteUtf8(Cfg.UpdateConf, sb.ToString());
        }

        private void LoadUpgrade()
        {
            Dictionary<string, string> c = Util.ReadKv(Cfg.UpdateConf);
            _updateUrl.Text = c.ContainsKey("UPDATE_URL") ? c["UPDATE_URL"] : "http://10.0.50.199:15889/geyi/update.manifest";
            _autoUpdate.Checked = !c.ContainsKey("AUTO_UPDATE") || c["AUTO_UPDATE"] != "0";
            int iv = 60;
            if (c.ContainsKey("CHECK_INTERVAL_MIN")) int.TryParse(c["CHECK_INTERVAL_MIN"], out iv);
            if (iv < 5 || iv > 1440) iv = 60;
            _interval.Value = iv;

            Dictionary<string, string> u = Updater.State();
            Dictionary<string, string> p = Updater.Pending();
            string txt = "本机版本   : " + Actions.VersionText() + "\r\n" +
                         "清单状态   : " + (u.ContainsKey("STATUS") ? u["STATUS"] : "未检查") + "\r\n" +
                         "清单版本   : " + (u.ContainsKey("NEW_VER") ? u["NEW_VER"] + " / " + u["NEW_BUILD"] : "-") + "\r\n" +
                         "灰度阶段   : " + (u.ContainsKey("PHASE") ? u["PHASE"] : "-") + "\r\n" +
                         "本机放行   : " + (u.ContainsKey("ALLOWED") ? u["ALLOWED"] : "-") + "\r\n" +
                         "本机名     : " + Environment.MachineName + "\r\n" +
                         "待安装     : " + (p.Count > 0 ? (p.ContainsKey("VER") ? p["VER"] + " / " + p["BUILD"] : "有") : "无") + "\r\n" +
                         "说明       : " + (u.ContainsKey("NOTE") ? u["NOTE"] : "-") + "\r\n" +
                         "上次检查   : " + (u.ContainsKey("TS") ? u["TS"] : "-") + "\r\n" +
                         "错误信息   : " + (u.ContainsKey("ERROR") ? u["ERROR"] : "-");
            _upgradeInfo.Text = txt;
            _btnInstallUpdate.Enabled = true;
        }
    }

    internal class TrayApp : ApplicationContext
    {
        private NotifyIcon _ni;
        private System.Windows.Forms.Timer _timer;
        private MenuItem _miState, _miServer, _miVer, _miSwitch, _miMode, _miUpdate, _miAuto, _miRotate;
        private string _lastColor = "", _menuSig = "";
        private int _rescueTick = 0;
        private int _healthTick = 0, _autoBadTicks = 0;
        private Dictionary<string, int> _health = new Dictionary<string, int>();
        private DateTime _lastBalloon = DateTime.MinValue;
        private bool _upgrading = false;
        private Icon _green, _yellow, _red, _gray;
        private static TrayApp _instance;

        public TrayApp()
        {
            _instance = this;
            _green = Util.StatusIcon("green");
            _yellow = Util.StatusIcon("yellow");
            _red = Util.StatusIcon("red");
            _gray = Util.StatusIcon("gray");

            ContextMenu cm = new ContextMenu();
            _miState = new MenuItem("状态: 检测中..."); _miState.Enabled = false;
            _miServer = new MenuItem("当前服务器: ..."); _miServer.Enabled = false;
            _miVer = new MenuItem("版本: " + L.Ver); _miVer.Enabled = false;
            cm.MenuItems.Add(_miState);
            cm.MenuItems.Add(_miServer);
            cm.MenuItems.Add(_miVer);
            cm.MenuItems.Add("-");

            _miMode = new MenuItem("运行模式");
            AddMenu(_miMode, "自动 (跟随在线监测 fail-open)", delegate { Actions.SetMode("Auto", "tray-menu"); });
            AddMenu(_miMode, "强制走当前代理", delegate { Actions.SetMode("On", "tray-menu"); });
            AddMenu(_miMode, "强制直连 (回家/断网)", delegate { Actions.SetMode("Off", "tray-menu"); });
            cm.MenuItems.Add(_miMode);

            _miAuto = new MenuItem("自动切换: 关");
            _miAuto.Click += delegate {
                bool now = !Actions.AutoSwitchEnabled();
                Actions.SetAutoSwitch(now);
                _miAuto.Text = "自动切换: " + (now ? "开" : "关");
                Balloon("格一代理 自动切换", now ? "已开启：当前节点连续3次异常时自动切到健康节点。" : "已关闭：仅手动切换。");
            };
            if (Actions.AutoSwitchEnabled()) _miAuto.Text = "自动切换: 开";
            cm.MenuItems.Add(_miAuto);

            // 1.3.0 random rotation
            _miRotate = new MenuItem("随机轮换: " + (Actions.RotateEnabled() ? "开" : "关") +
                                     "（每 " + Actions.RotateMinutes() + " 分钟）");
            _miRotate.Click += delegate {
                bool now = !Actions.RotateEnabled();
                Actions.SetRotate(now, Actions.RotateMinutes());
                _miRotate.Text = "随机轮换: " + (now ? "开" : "关") + "（每 " + Actions.RotateMinutes() + " 分钟）";
                Balloon("格一代理 随机轮换", now
                    ? "已开启：每 " + Actions.RotateMinutes() + " 分钟随机换一个海外出口节点（空闲时才切，不打断正在使用的会话）。"
                    : "已关闭：固定使用当前节点。");
            };
            cm.MenuItems.Add(_miRotate);
            AddMenu(cm, "轮换间隔...", delegate { ShowRotateDialog(); });

            _miSwitch = new MenuItem("切换代理服务器");
            cm.MenuItems.Add(_miSwitch);
            cm.MenuItems.Add("-");

            AddMenu(cm, "配置 / 服务器管理...", delegate { Actions.OpenConfig(); });
            AddMenu(cm, "立即重新检测", delegate { Actions.SetMode("Auto", "tray-detect"); });
            _miUpdate = new MenuItem("版本与更新");
            AddMenu(_miUpdate, "立即检查更新", delegate { Updater.Check(true, false); Balloon("格一代理 更新检查", "已完成，打开配置窗口可查看结果。"); });
            AddMenu(_miUpdate, "手动批准并安装更新", delegate { Updater.Check(true, true); Balloon("格一代理 更新", "已提交安装请求，托盘将在数秒内完成替换。"); });
            AddMenu(_miUpdate, "查看当前版本", delegate { MessageBox.Show(Actions.Status(), "格一代理 " + L.Ver, MessageBoxButtons.OK, MessageBoxIcon.Information); });
            cm.MenuItems.Add(_miUpdate);
            cm.MenuItems.Add("-");
            AddMenu(cm, "打开日志目录", delegate { try { Process.Start("explorer.exe", Cfg.Dir); } catch { } });
            AddMenu(cm, "查看状态", delegate { MessageBox.Show(Actions.Status(), "格一代理", MessageBoxButtons.OK, MessageBoxIcon.Information); });
            AddMenu(cm, "卸载 格一代理...", delegate { DoUninstall(); });
            AddMenu(cm, "退出托盘 (自动管理继续)", delegate { Exit(); });
            // 1.3.0 real exit: stops tray + guard tasks + run-at-login for good
            AddMenu(cm, "退出程序 (完全停止)", delegate { DoExitProgram(); });

            _ni = new NotifyIcon();
            _ni.Icon = _gray;
            _ni.Text = "格一代理: 启动中";
            _ni.ContextMenu = cm;
            _ni.DoubleClick += delegate { Actions.OpenConfig(); };
            _ni.Visible = true;

            _timer = new System.Windows.Forms.Timer();
            _timer.Interval = 5000;
            _timer.Tick += delegate { Tick(); };
            _timer.Start();
            try { File.Delete(Cfg.ExitFlag); } catch { }
            // 1.3.0: clear a stale quit flag on an explicit start, then arm the
            // rotation clock so a fresh install does not rotate immediately.
            if (File.Exists(Cfg.QuitFlag))
            {
                try { File.Delete(Cfg.QuitFlag); } catch { }
                Util.Log("quit flag cleared on explicit start");
            }
            Actions.InitRotateClock();
            RebuildServerMenu();
            Tick();
            Util.Log("TRAY started pid=" + Process.GetCurrentProcess().Id + " v" + L.Ver);
        }

        // Menu is the common base of both ContextMenu and MenuItem, and both
        // expose MenuItems - one helper serves the root menu and sub-menus.
        private void AddMenu(Menu parent, string text, EventHandler h)
        {
            MenuItem mi = new MenuItem(text);
            mi.Click += h;
            parent.MenuItems.Add(mi);
        }

        private void RebuildServerMenu()
        {
            try
            {
                string act = ServerStore.ActiveId();
                string hs = "";
                foreach (KeyValuePair<string, int> kv in _health) hs += kv.Key + kv.Value + ";";
                string sig = act + "|" + File.GetLastWriteTimeUtc(Cfg.ServersFile).Ticks + "|" + hs;
                if (sig == _menuSig) return;
                _menuSig = sig;
                _miSwitch.MenuItems.Clear();
                foreach (Srv s in ServerStore.Load())
                {
                    if (s.Enabled == "0") continue;
                    string id = s.Id;
                    int r = 0; if (_health.ContainsKey(id)) r = _health[id];
                    MenuItem mi = new MenuItem(HealthProbe.Mark(r) + s.Name + "   " + s.Address);
                    mi.Checked = (id == act);
                    mi.Click += delegate { Actions.SwitchServer(id, "tray-menu"); Balloon("格一代理 已切换服务器", s.Name + "\r\n" + s.Address); };
                    _miSwitch.MenuItems.Add(mi);
                }
                if (_miSwitch.MenuItems.Count == 0) _miSwitch.MenuItems.Add(new MenuItem("(无可用服务器)"));
            }
            catch (Exception e) { Util.Log("server menu: " + e.Message); }
        }

        public static void Balloon(string title, string text)
        {
            try
            {
                if (_instance == null || _instance._ni == null) return;
                _instance._ni.BalloonTipTitle = title;
                _instance._ni.BalloonTipText = text;
                _instance._ni.BalloonTipIcon = ToolTipIcon.Info;
                _instance._ni.ShowBalloonTip(3000);
            }
            catch { }
        }

        // 1.3.0 - full program exit (tray + guard + run-at-login all stopped)
        private void DoExitProgram()
        {
            DialogResult r = MessageBox.Show(
                "确定要完全退出「格一代理」吗？\r\n\r\n" +
                "将执行：\r\n" +
                "  · 关闭托盘图标\r\n" +
                "  · 停用在线监测与 CA 刷新计划任务（不再自动拉起）\r\n" +
                "  · 移除开机自启动项\r\n\r\n" +
                "注意：系统代理设置不会被改动；如需完全恢复直连，请在「运行模式」中选择「强制直连」。\r\n\r\n" +
                "之后可从桌面「格一代理」快捷方式重新启动。",
                "格一代理 - 退出程序", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (r != DialogResult.Yes) return;

            Actions.ExitProgram();
            Balloon("格一代理 已退出", "程序已完全停止，守护任务已停用。");
            try { _timer.Stop(); } catch { }
            try { _ni.Visible = false; _ni.Dispose(); } catch { }
            try { _green.Dispose(); _yellow.Dispose(); _red.Dispose(); _gray.Dispose(); } catch { }
            Util.Log("TRAY exit (full program exit)");
            ExitThread();
        }

        // 1.3.0 - rotation interval dialog (self-contained: no extra assembly refs)
        private void ShowRotateDialog()
        {
            int cur = Actions.RotateMinutes();
            using (Form f = new Form())
            using (NumericUpDown nud = new NumericUpDown())
            using (Button ok = new Button())
            using (Button cancel = new Button())
            using (Label tip = new Label())
            {
                f.Text = "格一代理 · 随机轮换间隔";
                f.FormBorderStyle = FormBorderStyle.FixedDialog;
                f.StartPosition = FormStartPosition.CenterScreen;
                f.ClientSize = new Size(340, 150);
                f.MinimizeBox = false; f.MaximizeBox = false;

                tip.Text = "每隔多少分钟随机换一个海外出口节点？\r\n（仅在空闲时切换，不打断正在使用的会话）";
                tip.SetBounds(12, 12, 310, 40);

                nud.Minimum = 5; nud.Maximum = 720; nud.Value = cur;
                nud.SetBounds(12, 60, 90, 23);

                ok.Text = "确定"; ok.DialogResult = DialogResult.OK;
                ok.SetBounds(12, 108, 80, 26);
                cancel.Text = "取消"; cancel.DialogResult = DialogResult.Cancel;
                cancel.SetBounds(100, 108, 80, 26);

                f.Controls.Add(tip); f.Controls.Add(nud); f.Controls.Add(ok); f.Controls.Add(cancel);
                f.AcceptButton = ok; f.CancelButton = cancel;
                if (f.ShowDialog() == DialogResult.OK)
                {
                    int mins = (int)nud.Value;
                    Actions.SetRotate(Actions.RotateEnabled(), mins);
                    _miRotate.Text = "随机轮换: " + (Actions.RotateEnabled() ? "开" : "关") + "（每 " + mins + " 分钟）";
                    Balloon("格一代理 随机轮换", "轮换间隔已设为 " + mins + " 分钟。");
                }
            }
        }

        private void DoUninstall()
        {            DialogResult r = MessageBox.Show(
                "确定要卸载 格一代理 吗？\r\n\r\n将清除：代理设置、根证书、计划任务、启动项、任务栏图标、服务器配置和程序文件。\r\n浏览器会恢复直连。",
                "格一代理 - 卸载确认", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (r != DialogResult.Yes) return;
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = Cfg.Exe;
                psi.Arguments = "/uninstall /silent";
                psi.UseShellExecute = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                Process.Start(psi);
            }
            catch (Exception e) { Util.Log("uninstall launch: " + e.Message); }
            Exit();
        }

        private void CheckPendingUpgrade()
        {
            if (_upgrading || !File.Exists(Cfg.PendingFlag)) return;
            Dictionary<string, string> p = Updater.Pending();
            if (!p.ContainsKey("PATH") || !File.Exists(p["PATH"]))
            {
                try { File.Delete(Cfg.PendingFlag); } catch { }
                return;
            }
            // Guard against downgrade loops: never install a version that is
            // not newer than the one already running. A stale pending flag
            // pointing at an OLD package would otherwise restart the tray
            // forever (install -> exit -> guard relaunch -> install ...).
            string pv = p.ContainsKey("VER") ? p["VER"].Trim() : "";
            if (pv.Length > 0)
            {
                try
                {
                    if (Util.CompareVer(pv, L.Ver) <= 0)
                    {
                        Util.Log("TRAY pending upgrade " + pv + " <= current " + L.Ver + " -> ignored, flag cleared");
                        try { File.Delete(Cfg.PendingFlag); } catch { }
                        return;
                    }
                }
                catch { }
            }
            _upgrading = true;
            Util.Log("TRAY pending upgrade -> launch /upgrade from " + p["PATH"]);
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = p["PATH"];
                psi.Arguments = "/upgrade /silent";
                psi.UseShellExecute = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;
                Process.Start(psi);
                Balloon("格一代理 自动升级", "已开始安装 " + (p.ContainsKey("VER") ? p["VER"] : "新版本") + "，托盘将自动重启。");
            }
            catch (Exception e) { Util.Log("upgrade launch failed: " + e.Message); _upgrading = false; return; }
            Exit();
        }

        private void Tick()
        {
            try
            {
                if (File.Exists(Cfg.ExitFlag)) { Exit(); return; }
                // 1.3.0: user chose "退出程序" -> stop everything for good.
                // The TrayGuard script also honours this flag, so the tray
                // will NOT be relaunched.
                if (Actions.IsQuitted())
                {
                    Util.Log("TRAY quit flag present -> full exit");
                    try { _timer.Stop(); } catch { }
                    try { _ni.Visible = false; _ni.Dispose(); } catch { }
                    ExitThread();
                    return;
                }
                CheckPendingUpgrade();
                if (_upgrading) return;
                RebuildServerMenu();

                // Multi-node health probe every 12 ticks (~60s). Never blocks UI long:
                // each probe has a 2.5s timeout; 5 nodes worst case ~12s but runs on the
                // timer thread and is failure-isolated.
                _healthTick++;
                if (_healthTick == 1 || _healthTick % 12 == 0)
                {
                    try
                    {
                        Dictionary<string, int> res = Actions.ProbeAll();
                        _health = res;
                        StringBuilder hb = new StringBuilder();
                        foreach (KeyValuePair<string, int> kv in res)
                            hb.Append(kv.Key + "=" + kv.Value + ";");
                        Util.WriteUtf8(Cfg.NodeHealthFile, "TS=" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\r\n" + hb.ToString());
                        // auto switch only when the guard heartbeat is fresh (avoid switching on a dead box)
                        if (Actions.AutoSwitchEnabled() && Util.StateAgeSeconds() <= 240)
                        {
                            string reason;
                            string switched = Actions.AutoSwitchTick(res, ref _autoBadTicks, 3, out reason);
                            if (switched.Length > 0)
                                Balloon("格一代理 自动切换", reason);
                        }
                        // 1.3.0 random rotation: only when due AND idle.
                        // Uses the SAME fresh health map, so it never rotates
                        // onto a node that is not verifiably healthy.
                        if (Actions.RotateEnabled() && Util.StateAgeSeconds() <= 240)
                        {
                            string rreason;
                            string rotated = Actions.RotateTick(res, 60, out rreason);
                            if (rotated.Length > 0)
                                Balloon("格一代理 随机轮换", rreason);
                        }
                    }
                    catch (Exception pe) { Util.Log("health probe: " + pe.Message); }
                }

                int age = Util.StateAgeSeconds();
                // Guard 心跳来自 PT1M 计划任务。电池供电/系统繁忙时任务可能延后若干周期,
                // 阈值给到 240s(4 个周期), 避免短暂延迟被误判成"在线监测挂了"。
                bool stale = age > 240;
                if (stale)
                {
                    _rescueTick++;
                    if (_rescueTick % 6 == 1)
                    {
                        Util.Log("TRAY rescue: guard stale " + age + "s (keep user mode)");
                        // 自救只补一次决策/心跳, 绝不把用户手选的 On/Off 强行改回 Auto。
                        string keep = File.Exists(Cfg.ModeFile) ? File.ReadAllText(Cfg.ModeFile).Trim() : "Auto";
                        if (keep != "Auto" && keep != "On" && keep != "Off") keep = "Auto";
                        Actions.SetMode(keep, "tray-rescue");
                    }
                }

                Dictionary<string, string> st = Util.ReadState();
                string mode = File.Exists(Cfg.ModeFile) ? File.ReadAllText(Cfg.ModeFile).Trim() : "Auto";
                Srv s = ServerStore.Active();
                string color = st.ContainsKey("COLOR") ? st["COLOR"] : "gray";
                if (stale) color = "gray";
                string text;
                if (color == "green") text = s.Name + " 代理生效 / 海外可访问";
                else if (color == "red") text = s.Name + " 不可达 / 代理仍开(断网风险)";
                else if (color == "yellow") text = "直连中 (离开公司或手动关闭)";
                else text = "等待在线监测状态";
                if (mode != "Auto") text = text + "  [" + mode + "]";

                Icon want = _gray;
                if (color == "green") want = _green;
                else if (color == "yellow") want = _yellow;
                else if (color == "red") want = _red;
                if (color != _lastColor)
                {
                    _ni.Icon = want;
                    // 心跳超时/恢复(gray <-> 其它色)只静默换图标, 不弹气泡;
                    // 真实颜色变化也做 2 分钟冷却, 杜绝"等待在线监测/海外可访问"交替弹窗。
                    bool heartbeatFlap = (color == "gray" || _lastColor == "gray");
                    if (_lastColor.Length > 0 && !heartbeatFlap &&
                        (DateTime.Now - _lastBalloon).TotalMinutes >= 2)
                    {
                        Balloon("格一代理 状态变化", text);
                        _lastBalloon = DateTime.Now;
                    }
                    _lastColor = color;
                }
                string tip = "格一代理 v" + L.Ver + ": " + text;
                if (tip.Length > 60) tip = tip.Substring(0, 60);
                _ni.Text = tip;
                _miState.Text = "状态: " + text;
                _miServer.Text = "当前服务器: " + s.Name + "  " + s.Address;
                _miVer.Text = "版本: " + Actions.VersionText();
            }
            catch (Exception e) { Util.Log("TRAY tick: " + e.Message); }
        }

        private new void Exit()
        {
            try { _timer.Stop(); } catch { }
            try { _ni.Visible = false; _ni.Dispose(); } catch { }
            try { _green.Dispose(); _yellow.Dispose(); _red.Dispose(); _gray.Dispose(); } catch { }
            Util.Log("TRAY exit");
            ExitThread();
        }
    }

    internal static class Program
    {
        private static Mutex _mutex;

        [STAThread]
        private static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string a0 = "";
            if (args != null && args.Length > 0) a0 = args[0].ToLowerInvariant().Replace("--", "/");
            bool silent = Has(args, "/silent");
            string a1 = (args != null && args.Length > 1) ? args[1] : "";

            if (a0 == "/uninstall") { Installer.Uninstall(silent); return 0; }
            if (a0 == "/install") { Installer.Run(silent, true); return 0; }
            if (a0 == "/upgrade") { Updater.RunUpgrade(); return 0; }
            if (a0 == "/config") return RunConfig();
            if (a0 == "/status") { MessageBox.Show(Actions.Status(), "格一代理", MessageBoxButtons.OK, MessageBoxIcon.Information); return 0; }
            if (a0 == "/version")
            {
                string t = L.App + " " + L.Ver + "\r\nBUILD=" + L.Build + "\r\nCFGVER=" + L.CfgVer + "\r\nAssembly=" + Assembly.GetExecutingAssembly().GetName().Version;
                try { Util.WriteUtf8(Cfg.P("version_output.txt"), t); } catch { }
                if (!silent) MessageBox.Show(t, "格一代理 - 版本", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 0;
            }
            if (a0 == "/servers")
            {
                StringBuilder sb = new StringBuilder();
                string act = ServerStore.ActiveId();
                foreach (Srv s in ServerStore.Load())
                    sb.AppendLine((s.Id == act ? "* " : "  ") + s.Id + "|" + s.Name + "|" + s.Address + "|" + s.CaMode + "|" + s.CaUrl);
                try { Util.WriteUtf8(Cfg.P("servers_output.txt"), sb.ToString()); } catch { }
                if (!silent) MessageBox.Show(sb.ToString(), "格一代理 - 服务器列表", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 0;
            }
            if (a0 == "/checkupdate") { Updater.Check(true, false); return 0; }
            if (a0 == "/approve") { Updater.Check(true, true); return 0; }
            if (a0 == "/setmode") { Actions.SetMode(a1, "command-line"); return 0; }
            if (a0 == "/switch") { Actions.SwitchServer(a1, "command-line"); return 0; }
            if (a0 == "/autoswitch") { Actions.SetAutoSwitch(a1 == "on" || a1 == "1"); return 0; }
            if (a0 == "/tray") return RunTray();

            if (!Installer.IsInstalled()) Installer.Run(true, false);
            else { try { File.Delete(Path.Combine(Cfg.Dir, "tray_disabled.flag")); } catch { } }
            return RunTray();
        }

        private static bool Has(string[] args, string flag)
        {
            if (args == null) return false;
            foreach (string a in args) if (string.Compare(a, flag, true) == 0) return true;
            return false;
        }

        private static int RunConfig()
        {
            bool created;
            Mutex m = null;
            try { m = new Mutex(true, L.ConfigMutex, out created); }
            catch { created = true; }
            if (!created) return 0;
            Application.Run(new ConfigForm());
            GC.KeepAlive(m);
            return 0;
        }

        private static int RunTray()
        {
            bool created;
            try { _mutex = new Mutex(true, L.Mutex, out created); }
            catch { created = true; }
            if (!created) { Util.Log("TRAY already running, exit"); return 0; }
            // 1.3.0: an explicit start means "I want this running".
            // 「退出程序」had removed the guard tasks + run-at-login entry,
            // so restore them here. The quit flag itself is cleared inside
            // the TrayApp constructor.
            try
            {
                bool hadQuit = File.Exists(Cfg.QuitFlag);
                if (hadQuit) Util.Log("TRAY start after 退出程序 -> restoring guard tasks + startup entry");
                Util.TaskCtl("install");
                try
                {
                    using (RegistryKey rk = Registry.CurrentUser.OpenSubKey(L.RunKey, true))
                    {
                        if (rk != null) rk.SetValue(L.RunName, "\"" + Cfg.Exe + "\" /tray", RegistryValueKind.String);
                    }
                }
                catch { }
            }
            catch (Exception e) { Util.Log("restore guard tasks failed: " + e.Message); }
            Application.Run(new TrayApp());
            GC.KeepAlive(_mutex);
            return 0;
        }
    }
}
