<#
  DSH 插件安装器 · 命令行模式（给愿意敲命令的人用）
  ------------------------------------------------------------------
  用法示例：
    powershell -File 命令行模式.ps1 -Action status
    powershell -File 命令行模式.ps1 -Action install -PluginPath "C:\...\dsh-unrestricted-0.2.4" -Profiles desktop
    powershell -File 命令行模式.ps1 -Action uninstall -PluginName dsh-unrestricted -Profiles desktop
    powershell -File 命令行模式.ps1 -Action unlock          # 解除插件版本限制
    powershell -File 命令行模式.ps1 -Action restore-official # 还原官方文件
    powershell -File 命令行模式.ps1 -Action autoheal        # DSH 更新后自动重打补丁
    powershell -File 命令行模式.ps1 -Action dir-on          # 应急：改用目录加载（绕开 asar 校验）
    powershell -File 命令行模式.ps1 -Action dir-off         # 应急：还原成 asar 加载
    powershell -File 命令行模式.ps1 -Action fuse-off        # 应急：降低 exe 里的检测强度
    powershell -File 命令行模式.ps1 -Action fuse-restore    # 应急：恢复 exe 官方状态
#>

param(
    [ValidateSet('install', 'uninstall', 'status', 'list', 'unlock', 'restore-official', 'autoheal', 'dir-on', 'dir-off', 'fuse-off', 'fuse-restore')]
    [string]$Action = 'status',
    [string]$PluginPath = '',
    [string[]]$Profiles = @(),
    [string]$PluginName = '',
    [switch]$EnableConfig,
    [switch]$ForceVersion,
    [switch]$ManualMode
)

$ErrorActionPreference = 'Stop'
$core = Join-Path $PSScriptRoot 'core\dsh-plugin-core.ps1'
if (-not (Test-Path -LiteralPath $core)) { throw "找不到核心文件：$core" }
. $core
$unlockCore = Join-Path $PSScriptRoot 'core\dsh-unlock-core.ps1'
if (-not (Test-Path -LiteralPath $unlockCore)) { throw "找不到核心文件：$unlockCore" }
. $unlockCore
$fallbackCore = Join-Path $PSScriptRoot 'core\dsh-fallback-core.ps1'
if (-not (Test-Path -LiteralPath $fallbackCore)) { throw "找不到核心文件：$fallbackCore" }
. $fallbackCore

$logDir = Join-Path $PSScriptRoot 'logs'
$logPath = Join-Path $logDir ('cli-{0}-{1}.log' -f $Action, (Get-Date -Format 'yyyyMMdd-HHmmss'))

if ($Action -eq 'list') {
    Write-Host '=== 发现到的插件 ==='
    $cands = Find-CandidatePlugins
    if (@($cands).Count -eq 0) { Write-Host '（没有找到，试试 -Action install -PluginPath <文件夹>）' }
    foreach ($c in $cands) { Write-Host ('  ' + $c.Label + '  ->  ' + $c.Path) }
    Write-Host ''
    Write-Host '=== 配置目录 ==='
    foreach ($p in (Get-DshProfiles)) {
        Write-Host ('  ' + $p.Name + '  初始化=' + $p.Initialized + '  依赖数=' + $p.DependencyCount + '  ' + $p.Dir)
    }
    exit 0
}

if ($Action -eq 'unlock' -or $Action -eq 'restore-official' -or $Action -eq 'autoheal') {
    $st = Get-UnlockStatus
    Write-Host ('解除限制可用：' + $st.Supported + '（' + $st.Reason + '）')
    Write-Host ('当前状态：' + $(if ($st.Applied) { '已解除' } else { '未解除（官方原版）' }))
    Write-Host ('补丁位置：' + $st.ModuleEntry + ' / ' + $st.PatchId + '   自动修复：' + $st.AutoHeal)
    if (-not $st.Supported) { exit 1 }
    if ($Action -eq 'unlock') {
        $r = Invoke-UnlockWorkflow -LogFile $logPath
    } elseif ($Action -eq 'autoheal') {
        $r = Invoke-UnlockWorkflow -LogFile $logPath -AutoHeal
    } else {
        $r = Invoke-UnlockWorkflow -LogFile $logPath -Restore
    }
    Write-Host ''
    if ($r.Ok) { Write-Host $r.Message; Write-Host '请重启 DeepSeek Harness 生效。'; exit 0 }
    Write-Host ('失败：' + $r.Error)
    Write-Host ('日志：' + $logPath)
    exit 1
}

if ($Action -in @('dir-on', 'dir-off', 'fuse-off', 'fuse-restore')) {
    $fb = Get-FallbackStatus
    $modeText = if ($fb.DirMode) { '目录模式' } else { 'asar 模式' }
    $fuseText = if ($fb.FuseIntegrityOn) { '开' } else { '关' }
    $signText = if ($fb.SignatureOk) { '有效' } else { '已失效' }
    Write-Host ('应急开关可用：' + $fb.Supported + '（' + $fb.Reason + '）')
    Write-Host ('当前模式：' + $modeText + '   完整性校验=' + $fuseText + '   签名=' + $signText)
    if (-not $fb.Supported) { exit 1 }
    $r = Invoke-FallbackWorkflow -LogFile $logPath -Action $Action
    Write-Host ''
    if ($r.Ok) { Write-Host $r.Message; Write-Host '请重启 DeepSeek Harness 生效。'; exit 0 }
    Write-Host ('失败：' + $r.Error)
    Write-Host ('日志：' + $logPath)
    exit 1
}

if (@($Profiles).Count -eq 0) { $Profiles = @('desktop') }

switch ($Action) {
    'status' {
        $r = Invoke-StatusWorkflow -PluginPath $PluginPath -LogFile $logPath
        Write-Host ''
        if ($r.Ok) { Write-Host ('检查完成，日志：' + $logPath) } else { Write-Host ('检查失败：' + $r.Error); exit 1 }
    }
    'install' {
        $r = Invoke-InstallWorkflow -PluginPath $PluginPath -Profiles $Profiles -EnableConfig:$EnableConfig `
            -ForceVersion:$ForceVersion -ManualMode:$ManualMode -LogFile $logPath
        Write-Host ''
        if ($r.Ok) {
            Write-Host ('安装成功：' + $r.Message)
            Write-Host '下一步：启动 DSH，在「插件」页面确认插件已开启。'
        } else {
            Write-Host ('安装失败：' + $r.Error)
            Write-Host ('日志：' + $logPath)
            exit 1
        }
    }
    'uninstall' {
        if (-not $PluginName) { throw '卸载需要 -PluginName <插件名>' }
        $r = Invoke-UninstallWorkflow -PluginName $PluginName -Profiles $Profiles -DeleteCopy -LogFile $logPath
        Write-Host ''
        if ($r.Ok) { Write-Host ('卸载完成：' + $r.Message) } else { Write-Host ('卸载失败：' + $r.Error); exit 1 }
    }
}
