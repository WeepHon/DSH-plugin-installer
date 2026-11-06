. "$PSScriptRoot\dsh-unlock-core.ps1"

# ------------------------------------------------------------------ 应急手段（fuse / 目录加载）
#
#  官方哪天把 asar 完整性校验打开，改 app.asar 会让程序起不来。这里给两条"备用腿"：
#
#    1. 关掉校验开关（改 exe 里的 fuse 字节）
#         代价：DeepSeek Harness.exe 的官方数字签名失效，SmartScreen 可能提示"未知发布者"。
#         可以随时改回来（我们记了原值）。
#
#    2. 改成"目录模式"加载（不走 asar）
#         Electron 的 OnlyLoadAppFromAsar 为 OFF 时，会把 resources\app 目录当成应用本体。
#         把 app.asar 摊开成 resources\app 再把 app.asar 改名，就没有 asar 可校验了。
#         代价：占约 360 MB 磁盘；启动稍慢；卸载 DSH 时要先还原。
#
#  两条都不动用户的插件和配置，状态存在 ~\.dsh 下，随时能撤销。

$script:FuseKeys = @(
    'RunAsNode',
    'EnableCookieEncryption',
    'EnableNodeOptionsEnvironmentVariable',
    'EnableNodeCliInspectArguments',
    'EnableEmbeddedAsarIntegrityValidation',
    'OnlyLoadAppFromAsar',
    'LoadBrowserProcessSpecificV8Snapshot',
    'GrantFileProtocolExtraPrivileges',
    'WasmTrapHandlers'
)

function Get-FuseStatePath { return (Join-Path (Get-DshHomePath) 'plugin-installer-fuse.json') }
function Get-DirModeStatePath { return (Join-Path (Get-DshHomePath) 'plugin-installer-dirmode.json') }

# ---------------------------------------------------------------- 通用小工具

function Test-IsProcessLockedError {
    param([string]$Message)
    return ($Message -match 'being used by another process|另一个程序|正在使用|拒绝访问|Access is denied')
}

function Get-CurrentDshProcesses {
    $names = @('DeepSeek Harness', 'dsh')
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName })
}

function Get-PathFreeSpaceMB {
    param([string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        $d = New-Object System.IO.DriveInfo $root
        return [math]::Round($d.AvailableFreeSpace / 1MB, 1)
    } catch { return -1 }
}

# ---------------------------------------------------------------- fuse 读写

function Get-FuseTable {
    param([string]$ExePath)
    $node = Get-NodeExe
    $tool = Get-AsarToolPath
    if (-not $node -or -not $tool) { return @() }
    $r = Invoke-AsarTool -NodeExe $node -ToolPath $tool -Arguments @('fuses', $ExePath)
    if (-not $r.Ok) { return @() }
    $rows = @()
    foreach ($line in ($r.Output -split "`n")) {
        $m = [regex]::Match($line, '^\s*\[(\d+)\]\s+(ON|OFF)\s+(\S+)')
        if ($m.Success) {
            $rows += [pscustomobject]@{
                Index      = [int]$m.Groups[1].Value
                State      = $m.Groups[2].Value
                Name       = $m.Groups[3].Value
                On         = ($m.Groups[2].Value -eq 'ON')
                ByteOffset = 0
            }
        }
    }
    return $rows
}

function Get-FuseRow {
    param($Rows, [string]$Name)
    foreach ($r in @($Rows)) { if ($r.Name -eq $Name) { return $r } }
    return $null
}

function Read-FuseRecord {
    $p = Get-FuseStatePath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Write-FuseRecord {
    param($Record)
    $p = Get-FuseStatePath
    $json = $Record | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-FuseRecord {
    $p = Get-FuseStatePath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}

<#
  改一个 fuse 的值，并读回校验。第一次改的时候把原值记进 plugin-installer-fuse.json。
#>
function Invoke-FuseSet {
    param(
        [string]$ExePath,
        [string]$Name,
        [bool]$On
    )

    $before = Get-FuseTable -ExePath $ExePath
    $row = Get-FuseRow -Rows $before -Name $Name
    if (-not $row) { throw ('这个版本里没有 ' + $Name + ' 这个开关') }
    if ($row.On -eq $On) { return $true }

    $rec = Read-FuseRecord
    if (-not $rec) {
        $orig = [ordered]@{}
        foreach ($r in $before) { $orig[$r.Name] = $r.State }
        $rec = [ordered]@{
            ExePath   = $ExePath
            Original  = $orig
            ChangedAt = (Get-Date).ToString('s')
        }
    }
    Write-FuseRecord -Record $rec

    $node = Get-NodeExe
    $tool = Get-AsarToolPath
    $val = if ($On) { '1' } else { '0' }
    $r = Invoke-AsarTool -NodeExe $node -ToolPath $tool -Arguments @('fuses', $ExePath, ($Name + '=' + $val))
    if (-not $r.Ok) { throw ('改开关失败：' + $r.Output) }

    $after = Get-FuseTable -ExePath $ExePath
    $row2 = Get-FuseRow -Rows $after -Name $Name
    if (-not $row2 -or $row2.On -ne $On) { throw '改完读回来对不上，可能被安全软件挡住了' }
    return $true
}

<#
  把改过的 fuse 全部恢复成原值。
#>
function Invoke-FuseRestoreAll {
    param([string]$ExePath)
    $rec = Read-FuseRecord
    if (-not $rec) { return [pscustomobject]@{ Ok = $true; Message = '没有改过任何开关，不需要恢复' } }
    $rows = Get-FuseTable -ExePath $ExePath
    $fixed = @()
    $failed = @()
    foreach ($p in $rec.Original.PSObject.Properties) {
        $name = $p.Name
        $wantOn = ([string]$p.Value -eq 'ON')
        $cur = Get-FuseRow -Rows $rows -Name $name
        if (-not $cur) { continue }
        if ($cur.On -eq $wantOn) { continue }
        try {
            Invoke-FuseSet -ExePath $ExePath -Name $name -On $wantOn | Out-Null
            $fixed += $name
        } catch { $failed += ($name + '：' + $_.Exception.Message) }
    }
    if ($failed.Count -eq 0) { Remove-FuseRecord }
    return [pscustomobject]@{
        Ok      = ($failed.Count -eq 0)
        Message = if ($fixed.Count) { '已恢复：' + ($fixed -join '、') } else { '本来就是原值' }
        Failed  = $failed
    }
}

# ---------------------------------------------------------------- 目录模式

function Read-DirModeState {
    $p = Get-DirModeStatePath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Write-DirModeState {
    param($State)
    $p = Get-DirModeStatePath
    $json = $State | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-DirModeState {
    $p = Get-DirModeStatePath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- 状态

function Get-FallbackStatus {
    param([string]$AppDir)

    $st = [ordered]@{
        Supported    = $false
        Reason       = ''
        AppDir       = $null
        ExePath      = $null
        SignatureOk  = $false
        AsarExists   = $false
        AsarPath     = $null
        AsarSizeMB   = 0
        DirMode      = $false
        DirPath      = $null
        DirSizeMB    = 0
        FuseIntegrityOn = $false
        FuseOnlyAsarOn  = $false
        FuseChanged  = $false
        Running      = (Test-DshDesktopRunning)
        FreeMB       = 0
    }

    if (-not $AppDir) { $AppDir = Find-DshApp }
    $st.AppDir = $AppDir
    if (-not $AppDir) { $st.Reason = '没找到桌面版 DeepSeek Harness 的安装目录'; return [pscustomobject]$st }

    $exe = Get-DshExePath -AppDir $AppDir
    $st.ExePath = $exe
    if (-not $exe) { $st.Reason = '没找到 DeepSeek Harness.exe'; return [pscustomobject]$st }

    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction Stop
        $st.SignatureOk = ($sig.Status -eq 'Valid')
    } catch { }

    $asar = Get-DshAsarPath -AppDir $AppDir
    if ($asar) {
        $st.AsarExists = $true
        $st.AsarPath = $asar
        try { $st.AsarSizeMB = [math]::Round((Get-Item -LiteralPath $asar).Length / 1MB, 1) } catch { }
    }
    $dir = Get-DshAppDirPath -AppDir $AppDir
    $st.DirPath = $dir
    $st.DirMode = (Test-DshDirMode -AppDir $AppDir)
    if ($dir) {
        try {
            $sum = (Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum)
            $st.DirSizeMB = [math]::Round(($sum.Sum / 1MB), 1)
        } catch { }
    }

    $st.FreeMB = Get-PathFreeSpaceMB -Path $AppDir

    $rows = Get-FuseTable -ExePath $exe
    if ($rows.Count -eq 0) {
        $st.Reason = '读不到 DeepSeek Harness.exe 里的开关（可能被安全软件拦住）'
        return [pscustomobject]$st
    }
    $ri = Get-FuseRow -Rows $rows -Name 'EnableEmbeddedAsarIntegrityValidation'
    $ro = Get-FuseRow -Rows $rows -Name 'OnlyLoadAppFromAsar'
    $st.FuseIntegrityOn = [bool]($ri -and $ri.On)
    $st.FuseOnlyAsarOn = [bool]($ro -and $ro.On)
    $st.FuseChanged = [bool](Read-FuseRecord)
    $st.Supported = $true
    return [pscustomobject]$st
}

# ---------------------------------------------------------------- 目录模式开关

<#
  打开目录模式：把 asar 摊开成 resources\app，再把 app.asar 改名。
#>
function Invoke-EnableDirMode {
    param(
        [string]$AppDir,
        [string]$LogFile,
        [switch]$Force,
        [switch]$IgnoreRunning
    )
    if ($LogFile) { Set-InstallerLogFile -Path $LogFile }
    if (-not $AppDir) { $AppDir = Find-DshApp }
    if (-not $AppDir) { Write-InstallLog '没找到桌面版 DeepSeek Harness 的安装目录。' 'error'; return $false }

    $st = Get-FallbackStatus -AppDir $AppDir
    if (-not $st.Supported) { Write-InstallLog ('现在无法操作：' + $st.Reason) 'error'; return $false }
    if ($st.DirMode) { Write-InstallLog '现在已经是"目录模式"，不用再开一次。' 'info'; return @{ Ok = $true; Noop = $true } }
    if (-not $st.AsarExists) { Write-InstallLog '没找到 resources\app.asar，没办法摊开。' 'error'; return $false }
    if ($st.Running -and -not $IgnoreRunning) {
        Write-InstallLog 'DeepSeek Harness 正在运行，请先完全退出再操作（这次没有改动任何文件）。' 'error'
        return $false
    }
    if ($st.FuseOnlyAsarOn) {
        Write-InstallLog '这个版本被设成"只从 app.asar 加载"，目录模式用不了。请先点「降低检测强度」把 OnlyLoadAppFromAsar 关掉。' 'error'
        return $false
    }
    $dir = Join-Path $AppDir 'resources\app'
    if ((Test-Path -LiteralPath $dir) -and -not $Force) {
        Write-InstallLog 'resources\app 目录已经存在（不是本工具建的），为了不覆盖它，这里停手。' 'error'
        return $false
    }
    $needMB = [math]::Round($st.AsarSizeMB * 1.3, 0)
    if ($st.FreeMB -ge 0 -and $st.FreeMB -lt $needMB) {
        Write-InstallLog ('磁盘空间不够：还需要大约 ' + $needMB + ' MB，现在只剩 ' + $st.FreeMB + ' MB。') 'error'
        return $false
    }

    $node = Get-NodeExe
    $tool = Get-AsarToolPath
    if (-not $node -or -not $tool) { Write-InstallLog '缺少 node 或 tools\dsh-asar.cjs。' 'error'; return $false }

    $staging = Join-Path $AppDir ('resources\app.new-' + (Get-Date -Format 'HHmmss'))
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    Write-InstallLog ('第一步：把 app.asar 摊开成普通目录（约 ' + $st.AsarSizeMB + ' MB，一万多个文件，需要十几秒）…') 'step'
    $r = Invoke-AsarTool -NodeExe $node -ToolPath $tool -Arguments @('extractall', $st.AsarPath, $staging)
    if (-not $r.Ok) {
        Write-InstallLog ('摊开失败：' + $r.Output) 'error'
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
        return $false
    }
    Write-InstallLog $r.Output 'info'

    $count = 0
    try { $count = (Get-ChildItem -LiteralPath $staging -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count } catch { }
    if ($count -lt 1000) {
        Write-InstallLog ('摊开出来的文件太少（' + $count + ' 个），不敢用，已删除。') 'error'
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }

    Write-InstallLog '第二步：把 app.asar 改名为 app.asar.disabled…' 'step'
    $disabled = Get-DshAsarDisabledPath -AppDir $AppDir
    try {
        if (Test-Path -LiteralPath $disabled) { Remove-Item -LiteralPath $disabled -Force -ErrorAction Stop }
        Move-Item -LiteralPath $st.AsarPath -Destination $disabled -ErrorAction Stop
    } catch {
        $msg = $_.Exception.Message
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-IsProcessLockedError -Message $msg) {
            Write-InstallLog 'DeepSeek Harness 的主程序文件正被占用，请完全退出后再试（这次没有改动任何文件）。' 'error'
        } else {
            Write-InstallLog ('改名失败：' + $msg) 'error'
        }
        return $false
    }

    Write-InstallLog '第三步：把摊开的目录就位…' 'step'
    try {
        if ((Test-Path -LiteralPath $dir) -and $Force) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop }
        Move-Item -LiteralPath $staging -Destination $dir -ErrorAction Stop
    } catch {
        $msg = $_.Exception.Message
        Write-InstallLog ('就位失败：' + $msg + '，正在回滚…') 'error'
        try {
            if (Test-Path -LiteralPath $disabled) { Move-Item -LiteralPath $disabled -Destination (Join-Path $AppDir 'resources\app.asar') -ErrorAction Stop }
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Write-InstallLog '已回滚成原来的样子。' 'warn'
        } catch {
            Write-InstallLog ('回滚也失败了，请手动把 resources\app.asar.disabled 改回 app.asar：' + $_.Exception.Message) 'error'
        }
        return $false
    }

    $state = [ordered]@{
        Mode       = 'dir'
        AppDir     = $AppDir
        DirPath    = $dir
        AsarMoved  = $disabled
        Files      = $count
        CreatedAt  = (Get-Date).ToString('s')
        DshVersion = (Get-DshRuntimeVersion)
    }
    Write-DirModeState -State $state
    Write-InstallLog ('已切换到目录模式：' + $count + ' 个文件，现在走 resources\app 目录加载。') 'ok'
    Write-InstallLog '提示：重启 DeepSeek Harness 生效；如果之前解除过版本限制，请在目录模式下再点一次「解除限制」。' 'info'
    return $true
}

<#
  还原成 asar：删掉 resources\app 目录，把 app.asar.disabled 改回 app.asar。
#>
function Invoke-DisableDirMode {
    param(
        [string]$AppDir,
        [string]$LogFile,
        [switch]$IgnoreRunning
    )
    if ($LogFile) { Set-InstallerLogFile -Path $LogFile }
    if (-not $AppDir) { $AppDir = Find-DshApp }
    if (-not $AppDir) { Write-InstallLog '没找到桌面版 DeepSeek Harness 的安装目录。' 'error'; return $false }

    $st = Get-FallbackStatus -AppDir $AppDir
    if (-not $st.DirMode) { Write-InstallLog '现在就是 asar 加载方式，不需要还原。' 'info'; return @{ Ok = $true; Noop = $true } }
    if ($st.Running -and -not $IgnoreRunning) {
        Write-InstallLog 'DeepSeek Harness 正在运行，请先完全退出再操作（这次没有改动任何文件）。' 'error'
        return $false
    }
    $disabled = Get-DshAsarDisabledPath -AppDir $AppDir
    if (-not (Test-Path -LiteralPath $disabled)) {
        Write-InstallLog '找不到 app.asar.disabled，没办法还原成 asar。' 'error'
        return $false
    }
    $dir = Get-DshAppDirPath -AppDir $AppDir
    if ($dir) {
        Write-InstallLog ('删除 resources\app 目录（约 ' + $st.DirSizeMB + ' MB）…') 'step'
        try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop } catch {
            $msg = $_.Exception.Message
            if (Test-IsProcessLockedError -Message $msg) {
                Write-InstallLog '有文件正被占用，请完全退出 DeepSeek Harness 后再试。' 'error'
            } else {
                Write-InstallLog ('删除失败：' + $msg) 'error'
            }
            return $false
        }
    }
    Write-InstallLog '把 app.asar.disabled 改回 app.asar…' 'step'
    try {
        Move-Item -LiteralPath $disabled -Destination (Join-Path $AppDir 'resources\app.asar') -ErrorAction Stop
    } catch {
        Write-InstallLog ('改名失败：' + $_.Exception.Message) 'error'
        return $false
    }
    Remove-DirModeState
    if ((Test-DshDirMode -AppDir $AppDir)) { Write-InstallLog '还处于目录模式，可能没清理干净。' 'warn'; return $false }
    Write-InstallLog '已还原成原来的 asar 方式。重启 DeepSeek Harness 生效。' 'ok'
    return $true
}

# ---------------------------------------------------------------- 工作流入口

function Invoke-FallbackWorkflow {
    param(
        [string]$LogFile,
        [string]$AppDir,
        [string]$Action,
        [switch]$IgnoreRunning
    )
    if ($LogFile) { Set-InstallerLogFile -Path $LogFile }
    if (-not $AppDir) { $AppDir = Find-DshApp }

    $st = Get-FallbackStatus -AppDir $AppDir
    if (-not $st.Supported) {
        Write-InstallLog ('现在无法操作：' + $st.Reason) 'error'
        return [pscustomobject]@{ Ok = $false; Error = $st.Reason }
    }

    switch ($Action) {
        'fuse-off' {
            if ($st.Running -and -not $IgnoreRunning) {
                Write-InstallLog 'DeepSeek Harness 正在运行，请先完全退出再操作（这次没有改动任何文件）。' 'error'
                return [pscustomobject]@{ Ok = $false; Error = 'DeepSeek Harness 正在运行' }
            }
            if (-not $st.FuseIntegrityOn) {
                Write-InstallLog '这个版本的 asar 完整性校验本来就是关着的，不需要降低。' 'info'
                return [pscustomobject]@{ Ok = $true; Message = '本来就没开完整性校验' }
            }
            Write-InstallLog '修改 DeepSeek Harness.exe 里的校验开关…' 'step'
            try {
                Invoke-FuseSet -ExePath $st.ExePath -Name 'EnableEmbeddedAsarIntegrityValidation' -On $false | Out-Null
            } catch {
                Write-InstallLog ('失败：' + $_.Exception.Message) 'error'
                return [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
            }
            Write-InstallLog '已关闭 asar 完整性校验。' 'ok'
            Write-InstallLog '注意：exe 的官方数字签名因此失效，Windows 可能提示"未知发布者"。随时可以点「恢复官方签名状态」改回来。' 'warn'
            return [pscustomobject]@{ Ok = $true; Message = '已关闭 asar 完整性校验（exe 签名会失效）' }
        }
        'fuse-restore' {
            $rec = Read-FuseRecord
            if (-not $rec) { Write-InstallLog '没有改过开关，不需要恢复。' 'info'; return [pscustomobject]@{ Ok = $true; Message = '没有改过开关' } }
            if ($st.Running -and -not $IgnoreRunning) {
                Write-InstallLog 'DeepSeek Harness 正在运行，请先完全退出再操作（这次没有改动任何文件）。' 'error'
                return [pscustomobject]@{ Ok = $false; Error = 'DeepSeek Harness 正在运行' }
            }
            Write-InstallLog '把开关恢复成官方原值…' 'step'
            $r = Invoke-FuseRestoreAll -ExePath $st.ExePath
            if ($r.Ok) { Write-InstallLog ($r.Message) 'ok' } else { Write-InstallLog ('有开关恢复失败：' + ($r.Failed -join '；')) 'error' }
            return [pscustomobject]@{ Ok = [bool]$r.Ok; Message = $r.Message; Error = ($r.Failed -join '；') }
        }
        'dir-on' {
            $r = Invoke-EnableDirMode -AppDir $AppDir -IgnoreRunning:$IgnoreRunning
            if ($r -is [hashtable] -and $r.Noop) { return [pscustomobject]@{ Ok = $true; Message = '现在已经是目录模式了' } }
            if ($r) { return [pscustomobject]@{ Ok = $true; Message = '已切换到目录模式' } }
            return [pscustomobject]@{ Ok = $false; Error = '切换没有完成，请看上面的日志' }
        }
        'dir-off' {
            $r = Invoke-DisableDirMode -AppDir $AppDir -IgnoreRunning:$IgnoreRunning
            if ($r -is [hashtable] -and $r.Noop) { return [pscustomobject]@{ Ok = $true; Message = '现在就是 asar 加载方式，不需要还原' } }
            if ($r) { return [pscustomobject]@{ Ok = $true; Message = '已还原成 asar 方式' } }
            return [pscustomobject]@{ Ok = $false; Error = '还原没有完成，请看上面的日志' }
        }
        default {
            Write-InstallLog ('不认识的操作：' + $Action) 'error'
            return [pscustomobject]@{ Ok = $false; Error = '不认识的操作' }
        }
    }
}
