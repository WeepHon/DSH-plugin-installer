# ------------------------------------------------------------------ 目录模式支持
#
#  背景：官方如果打开 EnableEmbeddedAsarIntegrityValidation（asar 完整性校验），
#  改 app.asar 会导致程序起不来。但 Electron 还有一条路：OnlyLoadAppFromAsar 为 OFF 时，
#  它会把 resources\app 当成"解开的 asar"直接加载 —— 目录里就是普通文件，
#  没有 asar 也就没有 asar 完整性校验。
#
#  这个文件负责"目录模式"下的一整套读/写/自检，让解锁逻辑照样能用。

function Get-DshAppDirPath {
    param([string]$AppDir)
    if (-not $AppDir) { $AppDir = Find-DshApp }
    if (-not $AppDir) { return $null }
    $p = Join-Path $AppDir 'resources\app'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Get-DshAsarDisabledPath {
    param([string]$AppDir)
    if (-not $AppDir) { $AppDir = Find-DshApp }
    if (-not $AppDir) { return $null }
    return (Join-Path $AppDir 'resources\app.asar.disabled')
}

<#
  是不是"目录模式"：resources\app 目录存在，并且 app.asar 不在了（被改名）。
#>
function Test-DshDirMode {
    param([string]$AppDir)
    if (-not $AppDir) { $AppDir = Find-DshApp }
    if (-not $AppDir) { return $false }
    $dir = Get-DshAppDirPath -AppDir $AppDir
    if (-not $dir) { return $false }
    $asar = Get-DshAsarPath -AppDir $AppDir
    if ($asar) { return $false }
    return $true
}

<#
  在摊开的目录里找"插件版本检查"那个模块。
  先按 unlock-targets.json 的 moduleSearch 直接试，再用内容特征兜底。
  返回相对路径（用 / 分隔），找不到返回 $null。
#>
function Find-UnlockModuleInDir {
    param([string]$DirRoot)

    if (-not $DirRoot -or -not (Test-Path -LiteralPath $DirRoot)) { return $null }
    $tg = Get-UnlockTargets

    foreach ($rel in @($tg.moduleSearch)) {
        if (-not $rel) { continue }
        $fs = $rel -replace '/', '\'
        if (Test-Path -LiteralPath (Join-Path $DirRoot $fs)) { return $rel }
    }
    foreach ($rel in @(
        'dsh/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js',
        'dsh/node_modules/@deepseek-ai/dsh-app-boot/lib/index.mjs',
        'dsh/node_modules/@deepseek-ai/dsh-app-boot/lib/index.cjs'
    )) {
        if (Test-Path -LiteralPath (Join-Path $DirRoot ($rel -replace '/', '\'))) { return $rel }
    }

    # 内容搜索：整个目录只扫脚本文件，跳过超大文件
    $patterns = @($tg.moduleContentFallbacks)
    $files = Get-ChildItem -LiteralPath $DirRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.js', '.cjs', '.mjs', '.json') -and $_.Length -lt 8MB }
    foreach ($f in $files) {
        $text = $null
        try { $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) } catch { continue }
        if (-not $text -or $text.IndexOf("`0") -ge 0) { continue }
        foreach ($p in $patterns) {
            if (-not $p) { continue }
            if ([regex]::IsMatch($text, $p)) {
                return ($f.FullName.Substring($DirRoot.Length).TrimStart('\') -replace '\\', '/')
            }
        }
    }
    return $null
}

<#
  目录模式下的状态。不是目录模式就返回 $null，让 Get-UnlockStatus 走原来的 asar 逻辑。
#>
function Get-DirUnlockStatus {
    param([string]$AppDir)

    if (-not (Test-DshDirMode -AppDir $AppDir)) { return $null }
    if (-not $AppDir) { $AppDir = Find-DshApp }

    $status = [ordered]@{
        Supported     = $false
        Reason        = ''
        Mode          = 'dir'
        AppDir        = $AppDir
        AsarPath      = $null
        AsarSizeMB    = 0
        DirPath       = $null
        Applied       = $false
        ModuleEntry   = $null
        PatchId       = $null
        SignatureRisk = $false
        AutoHeal      = (Read-UnlockPrefs).AutoHeal
        FuseBlocked   = $false
        Running       = (Test-DshDesktopRunning)
    }

    $dir = Get-DshAppDirPath -AppDir $AppDir
    $status.DirPath = $dir

    $tool = Get-AsarToolPath
    $node = Get-NodeExe -AppDir $AppDir
    if (-not $node) { $status.Reason = '找不到可用的 node 运行时'; return [pscustomobject]$status }

    $entry = Find-UnlockModuleInDir -DirRoot $dir
    if (-not $entry) {
        $status.Reason = '在 resources\app 目录里找不到插件检查逻辑（官方可能重构了），可以往 core\unlock-targets.json 里补一条特征'
        return [pscustomobject]$status
    }
    $status.ModuleEntry = $entry
    $file = Join-Path $dir ($entry -replace '/', '\')
    try { $src = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8) } catch {
        $status.Reason = '读取目录里的模块失败：' + $_.Exception.Message
        return [pscustomobject]$status
    }
    $status.Supported = $true
    if ($src.Contains($script:UnlockMarker)) { $status.Applied = $true }

    try {
        $tg = Get-UnlockTargets
        if ($tg.signatureWatch -and [regex]::IsMatch($src, $tg.signatureWatch)) { $status.SignatureRisk = $true }
    } catch { }

    if (-not $status.Applied) {
        $patch = Select-UnlockPatch -Source $src
        if ($patch) { $status.PatchId = $patch.id }
        else { $status.Reason = '找不到可以打补丁的函数（官方结构变了），可往 core\unlock-targets.json 的 patches 里补一条正则' }
    }

    $st = Read-UnlockState
    if ($st -and $st.PatchId) { $status.PatchId = $st.PatchId }
    if ($st -and $st.Patched -eq $true -and -not $status.Supported) { $status.Applied = $true }
    return [pscustomobject]$status
}

<#
  目录模式下打补丁：直接改 resources\app 里的明文文件。
  流程：读原文 → 插一行 → 落地 → 用 node 真跑一次自检 → 不通过就写回原文。
#>
function Invoke-DirUnlock {
    param(
        [string]$AppDir,
        [string]$LogFile,
        [switch]$IgnoreRunning
    )
    if ($LogFile) { Set-InstallerLogFile -Path $LogFile }

    $status = Get-DirUnlockStatus -AppDir $AppDir
    if (-not $status) {
        Write-InstallLog '现在不是"目录模式"，无需这样操作。' 'error'
        return $false
    }
    if (-not $status.Supported) {
        Write-InstallLog ('现在无法操作：' + $status.Reason) 'error'
        return $false
    }
    if ($status.Applied) {
        Write-InstallLog '这个版本限制已经解除过了，不用再改一次。' 'info'
        return $true
    }
    if (-not $status.PatchId) {
        Write-InstallLog ('找不到可以打补丁的地方：' + $status.Reason) 'error'
        return $false
    }
    if ($status.Running -and -not $IgnoreRunning) {
        Write-InstallLog 'DeepSeek Harness 正在运行，请先完全退出再操作（这次没有改动任何文件）。' 'error'
        return $false
    }

    $dir = $status.DirPath
    $entry = $status.ModuleEntry
    $file = Join-Path $dir ($entry -replace '/', '\')
    $patch = $null
    foreach ($p in @((Get-UnlockTargets).patches)) { if ($p.id -eq $status.PatchId) { $patch = $p; break } }
    if (-not $patch) { $patch = @{ id = $status.PatchId; insert = 'return void 0;' } }

    Write-InstallLog ('目标文件：' + $entry) 'step'
    Write-InstallLog ('补丁点：' + $patch.id) 'info'

    $original = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
    $patched = Add-UnlockPatchToSource -Source $original -Patch $patch
    [System.IO.File]::WriteAllText($file, $patched, (New-Object System.Text.UTF8Encoding($false)))
    Write-InstallLog '已改写目录里的模块文件' 'info'

    Write-InstallLog '行为自检：用 node 直接加载改过的模块，试装一个"要求 DSH >=99.0.0"的假插件…' 'step'
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-dirunlock-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $check = $null
    try {
        $check = Invoke-UnlockBehaviorCheck -DirMode -NodePath (Get-NodeExe -AppDir $AppDir) `
            -ProbeAsar $dir -ModuleEntry $entry -PatchId $patch.id -WorkDir $work
    } catch {
        $check = [pscustomobject]@{ Status = 'error'; Detail = $_.Exception.Message }
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if ($check.Status -eq 'deny') {
        [System.IO.File]::WriteAllText($file, $original, (New-Object System.Text.UTF8Encoding($false)))
        Write-InstallLog ('自检没通过（' + $check.Detail + '），已经把文件改回原样，这次没有改动任何东西。') 'error'
        return $false
    }
    if ($check.Status -eq 'error') {
        [System.IO.File]::WriteAllText($file, $original, (New-Object System.Text.UTF8Encoding($false)))
        Write-InstallLog ('自检跑不起来（' + $check.Detail + '），为了安全已经把文件改回原样。') 'error'
        return $false
    }
    if ($check.Status -eq 'pass') {
        Write-InstallLog '行为自检通过：假插件被判定为"兼容"，补丁确实生效。' 'ok'
    } else {
        Write-InstallLog ('行为自检跳过：' + $check.Detail) 'warn'
    }

    $state = [ordered]@{
        Patched    = $true
        Mode       = 'dir'
        AppDir     = $status.AppDir
        DirPath    = $dir
        ModuleEntry = $entry
        PatchId    = $patch.id
        PatchTitle = ''
        PatchedAt  = (Get-Date).ToString('s')
        DshVersion = (Get-DshRuntimeVersion)
    }
    Write-UnlockState -State $state
    Write-InstallLog '已解除插件版本限制（目录模式）。重启 DeepSeek Harness 生效。' 'ok'
    return $true
}

<#
  目录模式下还原：把带标记的那一行删掉。
#>
function Invoke-DirRestore {
    param(
        [string]$AppDir,
        [string]$LogFile,
        [switch]$IgnoreRunning
    )
    if ($LogFile) { Set-InstallerLogFile -Path $LogFile }

    $status = Get-DirUnlockStatus -AppDir $AppDir
    if (-not $status) { Write-InstallLog '现在不是"目录模式"。' 'error'; return $false }
    if (-not $status.Supported) { Write-InstallLog ('现在无法操作：' + $status.Reason) 'error'; return $false }
    if (-not $status.Applied) {
        Write-InstallLog '现在就是官方原版，不需要还原（顺手清掉旧记录）。' 'info'
        Remove-UnlockState
        return $true
    }
    if ($status.Running -and -not $IgnoreRunning) {
        Write-InstallLog 'DeepSeek Harness 正在运行，请先完全退出再操作（这次没有改动任何文件）。' 'error'
        return $false
    }

    $file = Join-Path $status.DirPath ($status.ModuleEntry -replace '/', '\')
    Write-InstallLog '正在把补丁行删掉（还原官方原版）…' 'step'
    try {
        $src = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
        $clean = Remove-UnlockPatchFromSource -Source $src
        if ($clean.Contains($script:UnlockMarker)) { throw '标记没删干净' }
        [System.IO.File]::WriteAllText($file, $clean, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-InstallLog ('还原失败：' + $_.Exception.Message) 'error'
        return $false
    }
    Remove-UnlockState
    Write-InstallLog '已还原成官方原版。重启 DeepSeek Harness 后，版本限制会恢复成官方行为。' 'ok'
    return $true
}
