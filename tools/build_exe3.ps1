#requires -Version 5.1
# 重新编译 launcher：用 UseShellExecute=true，让子进程不继承父进程的 std 句柄
# （之前 CreateNoWindow 方式下，子进程继承了重定向句柄，PowerShell 起来就死）
param([string]$ExeName = 'HuaweiMouseTray.exe')

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$exePath = Join-Path $dir $ExeName
$icoPath = Join-Path $dir '..\icons\app.ico'
if (-not (Test-Path -LiteralPath $icoPath)) { $icoPath = Join-Path $dir 'preview\app.ico' }
if (-not (Test-Path -LiteralPath $icoPath)) { throw "icon not found: $icoPath" }

$code = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

public class Launcher
{
    static void Log(string msg)
    {
        try
        {
            File.AppendAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "start.log"),
                DateTime.Now.ToString("HH:mm:ss.fff") + "  " + msg + "\r\n");
        }
        catch { }
    }

    [STAThread]
    public static void Main(string[] args)
    {
        Log("entry args=[" + string.Join(" ", args) + "]");
        try
        {
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(dir, "HuaweiMouseTray.ps1");
            if (!File.Exists(script))
            {
                Log("script missing");
                MessageBox.Show("HuaweiMouseTray.ps1 not found:\n" + script, "NearLink Battery");
                return;
            }

            var sb = new StringBuilder();
            sb.Append("-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"");
            sb.Append(script);
            sb.Append("\"");
            foreach (string a in args) { sb.Append(' '); sb.Append(a); }

            var psi = new ProcessStartInfo("powershell.exe");
            psi.Arguments = sb.ToString();
            psi.UseShellExecute = true;          // 关键：不继承句柄，行为和双击一致
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.WorkingDirectory = dir;
            Log("starting: powershell " + psi.Arguments);
            var p = Process.Start(psi);
            Log("started pid=" + (p == null ? "?" : p.Id.ToString()));
        }
        catch (Exception ex)
        {
            Log("ERROR " + ex.ToString());
            MessageBox.Show(ex.Message, "NearLink Battery");
        }
    }
}
'@

$cp = New-Object System.CodeDom.Compiler.CompilerParameters
$cp.GenerateExecutable = $true
$cp.GenerateInMemory = $false
$cp.OutputAssembly = $exePath
$cp.CompilerOptions = '/target:winexe /win32icon:"' + $icoPath + '" /optimize+'
$null = $cp.ReferencedAssemblies.Add('System.dll')
$null = $cp.ReferencedAssemblies.Add('System.Windows.Forms.dll')

if (Test-Path -LiteralPath $exePath) {
    $procName = [IO.Path]::GetFileNameWithoutExtension($exePath)
    if ($procName) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 400
    Remove-Item -LiteralPath $exePath -Force
}

try { Add-Type -TypeDefinition $code -CompilerParameters $cp } catch { "compile note: $($_.Exception.Message)" }
if (-not (Test-Path -LiteralPath $exePath)) { throw 'compile produced no file' }
"built: $exePath  $((Get-Item $exePath).Length) bytes"
