using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

// DSH 插件安装器 · 单文件启动器
// 把随程序嵌入的脚本解压到 %LOCALAPPDATA%\DSH-Plugin-Installer\<构建号>，
// 再用系统自带的 Windows PowerShell 5.1 跑起来（-STA 是 WPF 必需的）。
internal static class Program
{
    private const string BuildId = "__BUILD_ID__";
    private const string AppTitle = "DSH 插件安装器";

    // 资源名 -> 解压后的相对路径
    private static readonly string[,] Files = new string[,]
    {
        { "main.ps1",            @"DSH-Plugin-Installer.ps1" },
        { "cli.ps1",             @"cli-mode.ps1" },
        { "core-plugin.ps1",     @"core\dsh-plugin-core.ps1" },
        { "core-unlock.ps1",     @"core\dsh-unlock-core.ps1" },
        { "core-unlock-dir.ps1", @"core\dsh-unlock-dir.ps1" },
        { "core-fallback.ps1",   @"core\dsh-fallback-core.ps1" },
        { "targets.json",        @"core\unlock-targets.json" },
        { "asar.cjs",            @"tools\dsh-asar.cjs" },
        { "readme.md",           @"使用说明.md" },
        { "preview.png",         @"界面预览.png" },
        { "plugins-note.txt",    @"plugins\把插件放这里.txt" },
        { "app.ico",             @"app.ico" },
        { "start.bat",           @"开始安装.bat" },
        { "cmd.bat",             @"命令行模式.bat" },
    };

    private static readonly string[] CliActions = new string[]
    {
        "install", "uninstall", "status", "list", "unlock",
        "restore-official", "autoheal", "dir-on", "dir-off", "fuse-off", "fuse-restore"
    };

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AllocConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleTitle(string title);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    [STAThread]
    private static int Main(string[] args)
    {
        bool quiet = false;
        foreach (string a in (args ?? new string[0]))
        {
            if (string.Equals(a, "-Quiet", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(a, "--quiet", StringComparison.OrdinalIgnoreCase)) quiet = true;
        }
        string[] realArgs = Array.FindAll(args ?? new string[0], a =>
            !string.Equals(a, "-Quiet", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(a, "--quiet", StringComparison.OrdinalIgnoreCase));

        bool wantsConsole = realArgs.Length > 0;
        bool pause = false;
        bool childNeedsConsole = false;
        if (wantsConsole)
        {
            bool redirected = false;
            try { redirected = Console.IsOutputRedirected; } catch { }
            if (redirected)
            {
                // 输出被重定向（脚本调用）：不分配控制台，让子进程直接写进那个管道/文件。
            }
            else if (GetConsoleWindow() != IntPtr.Zero)
            {
                // 从 cmd / PowerShell 里启动：继承现有窗口，不暂停。
                childNeedsConsole = false;
            }
            else
            {
                // 双击 / Start-Process：自己开一个窗口，跑完等一下好让人看清结果。
                AttachConsoleForOutput(false);
                pause = !quiet;
                childNeedsConsole = true;
            }
        }
        args = realArgs;

        try
        {
            string root = Prepare();
            if (root == null) return 1;

            string script;
            string[] passthrough;

            if (wantsConsole && Array.IndexOf(CliActions, args[0].ToLowerInvariant()) >= 0)
            {
                // 命令行模式：直接把参数交给 cli-mode.ps1
                script = Path.Combine(root, "cli-mode.ps1");
                passthrough = args;
            }
            else if (wantsConsole)
            {
                // 例如 -SelfTest
                script = Path.Combine(root, "DSH-Plugin-Installer.ps1");
                passthrough = args;
            }
            else
            {
                script = Path.Combine(root, "DSH-Plugin-Installer.ps1");
                passthrough = new string[0];
            }

            if (!File.Exists(script))
            {
                Fail("解压不完整，找不到：" + script);
                return 1;
            }

            string psExe = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(psExe)) psExe = "powershell.exe";

            var sb = new StringBuilder();
            sb.Append("-NoProfile -ExecutionPolicy Bypass -STA -File \"").Append(script).Append('"');
            foreach (string a in passthrough)
            {
                bool needsQuote = a.IndexOf(' ') >= 0;
                sb.Append(' ');
                if (needsQuote) sb.Append('"').Append(a).Append('"');
                else sb.Append(a);
            }

            var psi = new ProcessStartInfo(psExe, sb.ToString());
            psi.UseShellExecute = false;
            psi.CreateNoWindow = !(wantsConsole && childNeedsConsole);
            psi.WorkingDirectory = root;
            if (wantsConsole) { psi.RedirectStandardOutput = false; }

            Process p = Process.Start(psi);
            if (p == null) { Fail("无法启动 PowerShell。"); return 1; }
            p.WaitForExit();
            int code = p.ExitCode;
            p.Dispose();

            if (wantsConsole && pause)
            {
                Console.WriteLine();
                Console.WriteLine("（按任意键关闭这个窗口）");
                try { Console.ReadKey(true); } catch { }
            }
            return code;
        }
        catch (Exception ex)
        {
            Fail(ex.ToString());
            return 1;
        }
    }

    private static void AttachConsoleForOutput(bool hadConsole)
    {
        if (!hadConsole && !AllocConsole()) return;
        try { SetConsoleTitle(AppTitle + " · 命令行"); } catch { }
        Stream stdout = Console.OpenStandardOutput();
        var w = new StreamWriter(stdout, new UTF8Encoding(false));
        w.AutoFlush = true;
        Console.SetOut(w);
        Stream stderr = Console.OpenStandardError();
        var we = new StreamWriter(stderr, new UTF8Encoding(false));
        we.AutoFlush = true;
        Console.SetError(we);
        try { Console.OutputEncoding = Encoding.UTF8; } catch { }
    }

    // 解压嵌入的脚本，返回运行目录（失败返回 null）
    private static string Prepare()
    {
        string baseDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DSH-Plugin-Installer");
        // 允许用环境变量指定落点（便携版 / 排障用）
        string overrideDir = Environment.GetEnvironmentVariable("DSH_INSTALLER_HOME");
        if (!string.IsNullOrEmpty(overrideDir)) baseDir = overrideDir;
        string root = null;
        var roots = new List<string>();
        roots.Add(Path.Combine(baseDir, BuildId));
        try { roots.Add(Path.Combine(Path.GetTempPath(), "DSH-Plugin-Installer-" + BuildId)); } catch { }
        try { roots.Add(Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location), "_run_" + BuildId)); } catch { }
        foreach (string candidate in roots)
        {
            try
            {
                Directory.CreateDirectory(candidate);
                // 写一个探针文件，确认这个位置真的可写
                string probe = Path.Combine(candidate, ".write-test");
                File.WriteAllText(probe, "ok");
                File.Delete(probe);
                root = candidate;
                break;
            }
            catch { }
        }
        if (root == null)
        {
            Fail("无法创建临时文件夹（试过 LocalAppData、TEMP、程序所在目录）。请把程序放到桌面或 D 盘再试，或以管理员身份运行。");
            return null;
        }

        string marker = Path.Combine(root, ".extracted");
        if (File.Exists(marker))
        {
            try
            {
                if (File.ReadAllText(marker).Trim() == BuildId) return root;
            }
            catch { }
        }

        try
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
        catch { }
        Directory.CreateDirectory(root);

        Assembly asm = Assembly.GetExecutingAssembly();
        int count = Files.GetLength(0);
        for (int i = 0; i < count; i++)
        {
            string name = Files[i, 0];
            string rel = Files[i, 1];
            string dest = Path.Combine(root, rel);
            string dir = Path.GetDirectoryName(dest);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

            using (Stream s = asm.GetManifestResourceStream(name))
            {
                if (s == null)
                {
                    Fail("安装器文件损坏：缺少内嵌资源 " + name + "。请重新下载完整程序。");
                    return null;
                }
                using (var fs = new FileStream(dest, FileMode.Create, FileAccess.Write))
                {
                    s.CopyTo(fs);
                }
            }
        }
        File.WriteAllText(marker, BuildId);
        return root;
    }

    private static void Fail(string message)
    {
        // 依次尝试几个落点：程序所在目录 -> TEMP -> LocalAppData -> 用户目录
        string line = DateTime.Now.ToString("s") + "  " + message + Environment.NewLine;
        var candidates = new List<string>();
        try { candidates.Add(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location)); } catch { }
        try { candidates.Add(Path.GetTempPath()); } catch { }
        try { candidates.Add(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)); } catch { }
        try { candidates.Add(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)); } catch { }
        foreach (string dir in candidates)
        {
            if (string.IsNullOrEmpty(dir)) continue;
            try
            {
                File.AppendAllText(Path.Combine(dir, "dsh-installer-error.log"), line);
                break;
            }
            catch { }
        }
        if (GetConsoleWindow() != IntPtr.Zero)
        {
            try { Console.Error.WriteLine("[ERROR] " + message); } catch { }
            return;
        }
        try
        {
            MessageBox.Show(message, AppTitle + " · 出错了", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        catch
        {
            try { Console.Error.WriteLine(message); } catch { }
        }
    }
}
