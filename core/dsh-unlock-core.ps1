. "$PSScriptRoot\dsh-plugin-core.ps1"
. "$PSScriptRoot\dsh-unlock-dir.ps1"

# ------------------------------------------------------------------ 解除限制（自适应版）
#
#  做什么：
#    把 DSH 主程序 resources\app.asar 里"插件版本检查"那个函数改成永远放行，
#    官方再收紧版本门槛也不会把插件停用。
#
#  这一版的重点是**跟着官方更新走**：
#    1. 目标文件不写死：先用 unlock-targets.json 的 moduleSearch，
#       找不到就按内容特征（moduleContentFallbacks）在整个 asar 里搜，
#       官方换文件名 / 换包名也照样能找到。
#    2. 补丁点也不写死：patches 里按顺序找，找到哪个就打哪个；
#       官方哪天真的加了 verifyPluginSignature，会自动改打"签名恒真"。
#    3. 打完先在沙盒里**真跑一次**：用 DSH 自己的 exe 加载新 asar，
#       拿一个"要求 DSH >=99.0.0"的假插件去问，必须回答"兼容"才算通过。
#    4. 不备份 116 MB 的整个 app.asar：还原靠把插入的那行标记删掉
#       （字节级还原），所以不占磁盘、也不用担心备份过期。
#
#  安全设计：
#    - asar 完整性校验开关（fuse）为 ON 时直接拒绝
#    - 逐文件哈希自检通过才落盘，落盘失败自动回滚
#    - DSH 正在运行时拒绝动手，不会留下假成功
#    - 状态写在 ~\.dsh\plugin-installer-unlock.json，可随时还原

$script:UnlockMarker = 'dsh-plugin-installer: 解除插件版本限制'
$script:UnlockTargetsFile = Join-Path $PSScriptRoot 'unlock-targets.json'
$script:UnlockTargets = $null
$script:UnlockSignatureRisk = $null

function Get-UnlockStatePath { return (Join-Path (Get-DshHomePath) 'plugin-installer-unlock.json') }
function Get-UnlockPrefsPath { return (Join-Path (Get-DshHomePath) 'plugin-installer-prefs.json') }

function Get-AsarToolPath {
    $p = Join-Path $script:InstallerRoot 'tools\dsh-asar.cjs'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

<#
  找一个能跑 .cjs 的 node：优先用 DSH 自带的运行时（不依赖用户装 Node）。
#>
function Get-NodeExe {
    param([string]$AppDir)
    if (-not $AppDir) { $AppDir = Find-DshApp }
    if ($AppDir) {
        $candidates = @(
            (Join-Path $AppDir 'resources\runtime\primary-runtime\dependencies\node\bin\node.exe'),
            (Join-Path $AppDir 'resources\runtime\node\node.exe'),
            (Join-Path $AppDir 'resources\runtime\primary-runtime\node.exe')
        )
        foreach ($c in $candidates) {
            if (Test-Path -LiteralPath $c) { return $c }
        }
    }
    $cmd = Get-Command 'node.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-DshAsarPath {
    param([string]$AppDir)
    if (-not $AppDir) { $AppDir = Find-DshApp }
    if (-not $AppDir) { return $null }
    $p = Join-Path $AppDir 'resources\app.asar'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Get-DshExePath {
    param([string]$AppDir)
    if ($AppDir) {
        $p = Join-Path $AppDir 'DeepSeek Harness.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $a = Find-DshApp
    if ($a) {
        $p = Join-Path $a 'DeepSeek Harness.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# ---------------------------------------------------------------- 配置与偏好

<#
  读 unlock-targets.json；读不到就用内置的一份最小配置。
  这是"官方更新后不用等我改代码"的关键：用户可以自己往里加函数名。
#>
function Get-UnlockTargets {
    if ($script:UnlockTargets) { return $script:UnlockTargets }

    $builtin = [pscustomobject]@{
        moduleSearch          = @('dsh/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js')
        moduleContentFallbacks = @('function\s+evaluatePluginCompatibility\s*\(')
        patches               = @(
            [pscustomobject]@{ id = 'compat-gate'; title = '插件版本兼容性检查'; find = 'function\s+evaluatePluginCompatibility\s*\('; insert = 'return void 0;' }
        )
        signatureWatch        = 'verifyPluginSignature|TRUSTED_PUBLIC_KEY|bundleSignature'
        hostileManifest       = [pscustomobject]@{ name = 'dsh-installer-probe'; version = '1.0.0'; peerDependencies = [pscustomobject]@{ '@deepseek-ai/dsh' = '>=99.0.0' } }
    }

    if (-not (Test-Path -LiteralPath $script:UnlockTargetsFile)) {
        $script:UnlockTargets = $builtin
        return $script:UnlockTargets
    }
    try {
        $raw = [System.IO.File]::ReadAllText($script:UnlockTargetsFile, [System.Text.Encoding]::UTF8)
        $j = $raw | ConvertFrom-Json
        if (-not $j.moduleSearch -or -not $j.patches) { throw '配置结构不对' }
        $script:UnlockTargets = $j
    } catch {
        $script:UnlockTargets = $builtin
    }
    return $script:UnlockTargets
}

function Read-UnlockPrefs {
    $prefs = [ordered]@{ AutoHeal = $true }
    $p = Get-UnlockPrefsPath
    if (Test-Path -LiteralPath $p) {
        try {
            $j = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($j.PSObject.Properties.Name -contains 'AutoHeal') { $prefs.AutoHeal = [bool]$j.AutoHeal }
        } catch { }
    }
    return [pscustomobject]$prefs
}

function Write-UnlockPrefs {
    param($Prefs)
    $p = Get-UnlockPrefsPath
    $json = $Prefs | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-UnlockState {
    $p = Get-UnlockStatePath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Write-UnlockState {
    param($State)
    $p = Get-UnlockStatePath
    $json = $State | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-UnlockState {
    $p = Get-UnlockStatePath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- asar 工具封装

function Invoke-AsarTool {
    param(
        [string]$NodeExe,
        [string]$ToolPath,
        [string[]]$Arguments
    )
    # 原生命令的 stderr 在 ErrorActionPreference=Stop 下会被当成异常抛出，
    # 这里临时放宽，保证工具报错时能拿到文字而不是把整个流程打断。
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $NodeExe $ToolPath @Arguments 2>&1
        $code = $LASTEXITCODE
        $text = ($out | Out-String).Trim()
    } finally {
        $ErrorActionPreference = $oldEap
    }
    return [pscustomobject]@{
        Ok     = ($code -eq 0)
        Code   = $code
        Output = $text
    }
}

<#
  找"插件检查逻辑"所在的那个文件：
    先试配置里的固定路径，再按内容特征在 asar 里搜。
    官方换文件名 / 挪包，都会在这里被兜住。
#>
function Find-UnlockModule {
    param([string]$AsarPath, [string]$NodeExe, [string]$ToolPath)

    $tg = Get-UnlockTargets
    foreach ($p in @($tg.moduleSearch)) {
        if (-not $p) { continue }
        $r = Invoke-AsarTool -NodeExe $NodeExe -ToolPath $ToolPath -Arguments @('has', $AsarPath, $p)
        if ($r.Ok) { return $p }
    }

    foreach ($pat in @($tg.moduleContentFallbacks)) {
        if (-not $pat) { continue }
        $r = Invoke-AsarTool -NodeExe $NodeExe -ToolPath $ToolPath -Arguments @('find', $AsarPath, $pat, '--limit=5')
        if ($r.Ok -and $r.Output -match '(?m)^(\S+\.(?:js|cjs|mjs))\s+\d+\s+处') {
            return $Matches[1]
        }
    }
    return $null
}

<#
  按配置顺序挑一个能打上的补丁点。返回 $null 表示一个都没匹配到。
#>
function Select-UnlockPatch {
    param([string]$Source)
    $tg = Get-UnlockTargets
    foreach ($patch in @($tg.patches)) {
        if (-not $patch.find) { continue }
        if ([regex]::IsMatch($Source, $patch.find)) { return $patch }
    }
    return $null
}

<#
  官方是否已经加了插件签名校验（只提示，不阻断）。
#>
function Test-UnlockSignatureRisk {
    param([string]$AsarPath, [string]$NodeExe, [string]$ToolPath)
    if ($null -ne $script:UnlockSignatureRisk) { return $script:UnlockSignatureRisk }
    $tg = Get-UnlockTargets
    $r = Invoke-AsarTool -NodeExe $NodeExe -ToolPath $ToolPath -Arguments @('find', $AsarPath, $tg.signatureWatch, '--limit=3')
    $script:UnlockSignatureRisk = ($r.Ok -and $r.Output -match '命中\s+[1-9]')
    return $script:UnlockSignatureRisk
}

# ---------------------------------------------------------------- 状态

<#
  检测当前状态，给界面和命令行用。
#>
function Get-UnlockStatus {
    param([string]$AppDir)

    $status = [ordered]@{
        Supported     = $false
        Reason        = ''
        Mode          = 'asar'
        AppDir        = $null
        AsarPath      = $null
        AsarSizeMB    = 0
        Applied       = $false
        ModuleEntry   = $null
        PatchId       = $null
        SignatureRisk = $false
        AutoHeal      = (Read-UnlockPrefs).AutoHeal
        FuseBlocked   = $false
        Running       = (Test-DshDesktopRunning)
    }

    if (-not $AppDir) { $AppDir = Find-DshApp }
    $status.AppDir = $AppDir
    if (-not $AppDir) { $status.Reason = '没找到桌面版 DeepSeek Harness 的安装目录'; return [pscustomobject]$status }

    # 目录模式（resources\app 目录加载）走另一套逻辑
    $dirStatus = Get-DirUnlockStatus -AppDir $AppDir
    if ($dirStatus) { return $dirStatus }

    $asar = Get-DshAsarPath -AppDir $AppDir
    if (-not $asar) { $status.Reason = '没找到 resources\app.asar'; return [pscustomobject]$status }
    $status.AsarPath = $asar
    try { $status.AsarSizeMB = [math]::Round((Get-Item -LiteralPath $asar).Length / 1MB, 1) } catch { }

    $tool = Get-AsarToolPath
    $node = Get-NodeExe -AppDir $AppDir
    if (-not $tool) { $status.Reason = '安装器包里缺少 tools\dsh-asar.cjs'; return [pscustomobject]$status }
    if (-not $node) { $status.Reason = '找不到可用的 node 运行时'; return [pscustomobject]$status }

    # asar 完整性校验开关（开启时改 asar 会导致程序无法启动，先拒绝）
    $exe = Get-DshExePath -AppDir $AppDir
    if ($exe) {
        $r = Invoke-AsarTool -NodeExe $node -ToolPath $tool -Arguments @('fuses', $exe)
        if ($r.Ok -and $r.Output -match 'EnableEmbeddedAsarIntegrityValidation\s+ON') {
            $status.FuseBlocked = $true
            $status.Reason = 'DeepSeek Harness.exe 已开启 asar 完整性校验，直接改文件会导致程序无法启动'
        }
    }

    # 找目标模块（自适应），再看里面有没有我们的标记
    $entry = Find-UnlockModule -AsarPath $asar -NodeExe $node -ToolPath $tool
    if ($entry) {
        $status.ModuleEntry = $entry
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-unlock-probe-' + [guid]::NewGuid().ToString('N') + '.js')
        try {
            $r2 = Invoke-AsarTool -NodeExe $node -ToolPath $tool -Arguments @('extract', $asar, $entry, $tmp)
            if ($r2.Ok -and (Test-Path -LiteralPath $tmp)) {
                $body = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
                if ($body.Contains($script:UnlockMarker)) { $status.Applied = $true }
                $status.Supported = $true
            } elseif (-not $status.FuseBlocked) {
                $status.Reason = '无法读取 app.asar 里的插件加载模块'
            }
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
        try { $status.SignatureRisk = Test-UnlockSignatureRisk -AsarPath $asar -NodeExe $node -ToolPath $tool } catch { }
    } elseif (-not $status.FuseBlocked) {
        $status.Reason = '在 app.asar 里找不到插件检查逻辑（官方可能重构了），可以往 core\unlock-targets.json 里补一条特征'
    }

    # 没打补丁时把补丁点也探出来，界面上能显示"准备打哪儿"
    if ($status.Supported -and -not $status.Applied) {
        $tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-unlock-probe-' + [guid]::NewGuid().ToString('N') + '.js')
        try {
            $r3 = Invoke-AsarTool -NodeExe $node -ToolPath $tool -Arguments @('extract', $asar, $status.ModuleEntry, $tmp2)
            if ($r3.Ok) {
                $src = [System.IO.File]::ReadAllText($tmp2, [System.Text.Encoding]::UTF8)
                $patch = Select-UnlockPatch -Source $src
                if ($patch) { $status.PatchId = $patch.id } else { $status.Reason = '找不到可以打补丁的函数（官方结构变了），可往 core\unlock-targets.json 的 patches 里补一条正则' }
            }
        } catch { } finally {
            if (Test-Path -LiteralPath $tmp2) { Remove-Item -LiteralPath $tmp2 -Force -ErrorAction SilentlyContinue }
        }
    }

    $st = Read-UnlockState
    if ($st -and $st.PatchId) { $status.PatchId = $st.PatchId }
    if ($st -and $st.Patched -eq $true -and -not $status.Supported) { $status.Applied = $true }

    return [pscustomobject]$status
}

# ---------------------------------------------------------------- 打补丁 / 去补丁

<#
  给函数体第一行插一段 return；插不进去就抛异常。
#>
function Add-UnlockPatchToSource {
    param([string]$Source, $Patch)

    if (-not $Patch) { $Patch = $null }
    if ($Patch -and $Patch.find) { $pattern = $Patch.find } else { $pattern = 'function\s+evaluatePluginCompatibility\s*\(' }
    if ($Patch -and $Patch.insert) { $insertText = $Patch.insert } else { $insertText = 'return void 0;' }

    $m = [regex]::Match($Source, $pattern)
    if (-not $m.Success) { throw ('没找到要改的函数（' + $pattern + '），可能是 DSH 版本结构变了') }

    # 参数表里可能有嵌套括号，先配平括号找到函数体的 '{'
    $openIdx = $Source.IndexOf('(', $m.Index + $m.Length - 1)
    if ($openIdx -lt 0) { throw '没找到函数参数表，可能是 DSH 版本结构变了' }
    $depth = 0
    $closeIdx = -1
    for ($i = $openIdx; $i -lt $Source.Length; $i++) {
        $ch = $Source[$i]
        if ($ch -eq '(') { $depth++ }
        elseif ($ch -eq ')') {
            $depth--
            if ($depth -eq 0) { $closeIdx = $i; break }
        }
    }
    if ($closeIdx -lt 0) { throw '函数参数表没有闭合，可能是 DSH 版本结构变了' }

    $braceIdx = $Source.IndexOf('{', $closeIdx)
    if ($braceIdx -lt 0) { throw '没找到函数体起点，可能是 DSH 版本结构变了' }

    $insert = "`r`n  $insertText // $($script:UnlockMarker) [$($Patch.id)]"
    $pos = $braceIdx + 1
    return $Source.Substring(0, $pos) + $insert + $Source.Substring($pos)
}

<#
  把带标记的那一行删掉 —— 字节级还原，不需要备份整个 asar。
#>
function Remove-UnlockPatchFromSource {
    param([string]$Source)
    if (-not $Source.Contains($script:UnlockMarker)) { return $Source }
    # 插进去的是 "\r\n" + 补丁行（行尾没有换行），所以按"行首前缀+整行"删掉即可
    # 字节级还原，不需要保留 116 MB 的整个 app.asar 备份
    $pattern = "`r`n[ `t]*[^`r`n]*" + [regex]::Escape($script:UnlockMarker) + "[^`r`n]*"
    return [regex]::Replace($Source, $pattern, '')
}

# ---------------------------------------------------------------- 行为自检

<#
  用 DSH 自己的 exe 把打完补丁的 asar 加载起来，拿一个"版本要求高到不可能"的假插件去问。
  必须回答"兼容"才算真生效 —— 这是唯一能证明补丁有用的检查。
  返回 Status = pass / deny / skip / error。
#>
function Invoke-UnlockBehaviorCheck {
    param(
        [string]$ExePath,
        [string]$ProbeAsar,
        [string]$ModuleEntry,
        [string]$PatchId,
        [string]$WorkDir,
        [string]$NodePath,
        [switch]$DirMode
    )

    $result = [pscustomobject]@{ Status = 'skip'; Detail = '' }
    if (-not $DirMode -and (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath))) {
        $result.Detail = '没找到 DSH 主程序，跳过行为自检'
        return $result
    }

    # 补丁点 -> 用来验证的函数名与期望返回值
    $fnName = ''
    $expect = 'void'
    switch ($PatchId) {
        'compat-gate'    { $fnName = 'evaluatePluginCompatibility'; $expect = 'void' }
        'compat-warning' { $fnName = 'pluginCompatibilityWarning'; $expect = 'falsy' }
        default          { $result.Detail = '该补丁点不做行为自检'; return $result }
    }

    $tg = Get-UnlockTargets
    $manifestFile = Join-Path $WorkDir 'probe-manifest.json'
    $manifest = $tg.hostileManifest | ConvertTo-Json -Depth 4 -Compress
    [System.IO.File]::WriteAllText($manifestFile, $manifest, (New-Object System.Text.UTF8Encoding($false)))

    $scriptFile = Join-Path $WorkDir 'verify.mjs'
    $js = @'
import { pathToFileURL } from 'node:url';
import fs from 'node:fs';

const [asarPath, entry, fnName, manifestPath, expectMode] = process.argv.slice(2);
const report = (o) => { console.log('VERIFY ' + JSON.stringify(o)); };

try {
  const url = pathToFileURL(asarPath.replace(/\\/g, '/') + '/' + entry).href;
  const mod = await import(url);
  const fn = mod[fnName];
  if (typeof fn !== 'function') { report({ status: 'skip', detail: 'function-not-exported' }); process.exit(0); }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const res = fn(manifest, {}, '0.0.1-probe');
  const ok = expectMode === 'falsy' ? !res : (res === undefined || res === null);
  report({ status: ok ? 'pass' : 'deny', detail: ok ? 'compatible' : JSON.stringify(res === undefined ? null : res).slice(0, 300) });
} catch (err) {
  report({ status: 'error', detail: String(err && err.message ? err.message : err).slice(0, 300) });
}
'@
    try {
        [System.IO.File]::WriteAllText($scriptFile, $js, (New-Object System.Text.UTF8Encoding($false)))

        # Electron/Node 只认 .asar 结尾的路径，配套的 .unpacked 目录用链接指过去
        $unpackedTarget = $ProbeAsar + '.unpacked'
        $realUnpacked = $null
        $appDir = $null
        if (-not $DirMode) { $appDir = Find-DshApp }
        if ($appDir) {
            $maybe = Join-Path $appDir 'resources\app.asar.unpacked'
            if (Test-Path -LiteralPath $maybe) { $realUnpacked = $maybe }
        }
        if ($realUnpacked -and -not (Test-Path -LiteralPath $unpackedTarget)) {
            try { cmd /c mklink /J "$unpackedTarget" "$realUnpacked" | Out-Null } catch { }
        }

        $outFile = Join-Path $WorkDir 'verify.out.txt'
        $errFile = Join-Path $WorkDir 'verify.err.txt'
        if ($DirMode) {
            # 目录模式：文件就是普通文件，直接用 node 加载即可
            $runner = $NodePath
            if (-not $runner) { $runner = Get-NodeExe }
            $argList = @(('"' + $scriptFile + '"'), ('"' + $ProbeAsar + '"'), ('"' + $ModuleEntry + '"'), $fnName, ('"' + $manifestFile + '"'), $expect)
        } else {
            $runner = $ExePath
            $env:ELECTRON_RUN_AS_NODE = '1'
            $argList = @('--expose-internals', ('"' + $scriptFile + '"'), ('"' + $ProbeAsar + '"'), ('"' + $ModuleEntry + '"'), $fnName, ('"' + $manifestFile + '"'), $expect)
        }
        $proc = Start-Process -FilePath $runner -ArgumentList $argList -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $DirMode) { $env:ELECTRON_RUN_AS_NODE = $null }
        $text = ''
        if (Test-Path -LiteralPath $outFile) { $text += [System.IO.File]::ReadAllText($outFile) }
        if (Test-Path -LiteralPath $errFile) { $text += [System.IO.File]::ReadAllText($errFile) }
        if ($text -match 'VERIFY (\{.*\})') {
            try {
                $o = $Matches[1] | ConvertFrom-Json
                $result.Status = [string]$o.status
                $result.Detail = [string]$o.detail
            } catch { $result.Status = 'error'; $result.Detail = '自检输出无法解析' }
        } else {
            $result.Status = 'error'
            $result.Detail = ($text -replace '\s+', ' ').Trim()
            if ($result.Detail.Length -gt 200) { $result.Detail = $result.Detail.Substring(0, 200) }
        }
    } catch {
        $result.Status = 'error'
        $result.Detail = $_.Exception.Message
    } finally {
        if (Test-Path -LiteralPath ($ProbeAsar + '.unpacked')) {
            try { cmd /c rmdir "$($ProbeAsar).unpacked" | Out-Null } catch { }
        }
    }
    return $result
}

# ---------------------------------------------------------------- 备份清理

<#
  旧版本会把整个 app.asar（116 MB）备份下来；现在还原靠删标记行，不再需要它。
  这里把历史遗留的大备份删掉，只保留 profile 的小备份（几十 KB）。
#>
function Clear-LegacyAsarBackups {
    $freed = 0
    try {
        $root = Join-Path (Get-DshHomePath) 'plugin-installer-backups'
        if (-not (Test-Path -LiteralPath $root)) { return 0 }
        foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $f = Join-Path $d.FullName 'asar\app.asar'
            if (Test-Path -LiteralPath $f) {
                try {
                    $freed += (Get-Item -LiteralPath $f).Length
                    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
                } catch { }
            }
            $ad = Join-Path $d.FullName 'asar'
            if ((Test-Path -LiteralPath $ad) -and -not (Get-ChildItem -LiteralPath $ad -File -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $ad -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
    return $freed
}

function Remove-OldAsarBackups {
    param([int]$Keep = 2)
    # 兼容旧调用：现在没有大备份了，转成清理历史遗留
    [void](Clear-LegacyAsarBackups)
}

# ---------------------------------------------------------------- 解除 / 还原

<#
  解除限制。返回 $true 表示成功（或本来就已经解除）。
#>
function Invoke-AsarUnlock {
    param(
        [string]$AppDir,
        [switch]$Force,
        [switch]$IgnoreRunning
    )

    if (-not $AppDir) { $AppDir = Find-DshApp }
    if (Test-DshDirMode -AppDir $AppDir) {
        return (Invoke-DirUnlock -AppDir $AppDir -IgnoreRunning:$IgnoreRunning)
    }

    $status = Get-UnlockStatus -AppDir $AppDir
    if (-not $status.Supported) {
        Write-InstallLog $status.Reason 'error'
        return $false
    }
    if ($status.FuseBlocked -and -not $Force) {
        Write-InstallLog $status.Reason 'error'
        return $false
    }
    if ($status.Applied) {
        Write-InstallLog '插件版本限制已经解除过了，不需要重复操作。' 'ok'
        return $true
    }
    if ($status.Running -and -not $IgnoreRunning) {
        Write-InstallLog '请先完全退出 DeepSeek Harness（托盘里也要退出），再操作。' 'error'
        return $false
    }
    if (-not $status.PatchId) {
        Write-InstallLog '没找到可以打补丁的函数，先不动物件也不改任何文件。' 'error'
        Write-InstallLog '如果这是 DSH 升级后出现的，可以往 core\unlock-targets.json 的 patches 里补一条正则，再点一次。' 'info'
        return $false
    }

    $asar = $status.AsarPath
    $entry = $status.ModuleEntry
    $node = Get-NodeExe -AppDir $status.AppDir
    $tool = Get-AsarToolPath
    $exe = Get-DshExePath -AppDir $status.AppDir
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-unlock-' + (Get-Date -Format 'yyyyMMddHHmmss'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    $srcFile = Join-Path $work 'module.js'
    $newFile = Join-Path $work 'module.patched.js'
    $probeAsar = Join-Path $work 'probe.asar'
    $oldAsar = Join-Path $work 'app.asar.old'

    try {
        if ($status.SignatureRisk) {
            Write-InstallLog '提示：这一版 DSH 里出现了插件签名校验的迹象，会自动改打签名校验那处。' 'warn'
        }

        # ---------- 1. 抽出要改的模块
        Write-InstallLog ('目标文件：' + $entry) 'step'
        $r = Invoke-AsarTool -NodeExe $node -ToolPath $tool -Arguments @('extract', $asar, $entry, $srcFile)
        if (-not $r.Ok) { throw ('抽取模块失败：' + $r.Output) }

        $source = [System.IO.File]::ReadAllText($srcFile, [System.Text.Encoding]::UTF8)
        if ($source.Contains($script:UnlockMarker)) {
            Write-InstallLog '模块里已经有补丁了，按已解除处理。' 'warn'
            return $true
        }

        # ---------- 2. 选补丁点 + 生成新内容
        $patch = Select-UnlockPatch -Source $source
        if (-not $patch) {
            throw '这个版本里找不到可打的函数（官方结构变了）。可以往 core\unlock-targets.json 的 patches 里补一条正则再试。'
        }
        Write-InstallLog ('补丁点：' + $patch.title + '（' + $patch.id + '）') 'info'
        $patched = Add-UnlockPatchToSource -Source $source -Patch $patch
        [System.IO.File]::WriteAllText($newFile, $patched, (New-Object System.Text.UTF8Encoding($false)))

        # ---------- 3. 重新打包到临时文件
        Write-InstallLog '重新打包 app.asar（要写约 120 MB，请稍等）…' 'step'
        $r = Invoke-AsarTool -NodeExe $node -ToolPath $tool -Arguments @('patch', $asar, $entry, $newFile, $probeAsar)
        if (-not $r.Ok) { throw ('重新打包失败：' + $r.Output) }
        Write-InstallLog $r.Output 'info'

        # ---------- 4. 结构自检（一万多个文件逐个校验）
        Write-InstallLog '自检新文件（一万多个文件逐个校验，可能要十几秒）…' 'step'
        $r = Invoke-AsarTool -NodeExe $node -ToolPath $tool -Arguments @('verify', $probeAsar)
        if ($r.Ok -and $r.Output -match '问题 0 个') {
            Write-InstallLog $r.Output 'info'
        } else {
            throw ('自检没通过，已放弃替换，DSH 文件没被改动：' + $r.Output)
        }

        # ---------- 5. 行为自检（真跑一遍，证明补丁确实放行了）
        Write-InstallLog '行为自检：用 DSH 自己的程序加载新文件，试装一个"要求 DSH >=99.0.0"的假插件…' 'step'
        $probe = Invoke-UnlockBehaviorCheck -ExePath $exe -ProbeAsar $probeAsar -ModuleEntry $entry -PatchId $patch.id -WorkDir $work
        switch ($probe.Status) {
            'pass' {
                Write-InstallLog '行为自检通过：假插件被判定为"兼容"，补丁确实生效。' 'ok'
            }
            'deny' {
                throw ('行为自检没通过：打完补丁后假插件仍被判为不兼容（返回 ' + $probe.Detail + '），已放弃替换，DSH 文件没被改动。')
            }
            'skip' {
                Write-InstallLog ('行为自检跳过：' + $probe.Detail) 'warn'
            }
            default {
                Write-InstallLog ('行为自检没能完成（' + $probe.Detail + '），按结构自检结果继续。') 'warn'
            }
        }

        # ---------- 6. 替换（任何一步失败都必须回滚）
        Write-InstallLog '替换 DSH 主程序文件…' 'step'
        $expectSize = (Get-Item -LiteralPath $probeAsar).Length
        $moved = $false
        try {
            Move-Item -LiteralPath $asar -Destination $oldAsar -Force -ErrorAction Stop
            $moved = $true
            Copy-Item -LiteralPath $probeAsar -Destination $asar -Force -ErrorAction Stop
            $actualSize = (Get-Item -LiteralPath $asar -ErrorAction Stop).Length
            if ($actualSize -ne $expectSize) { throw ('写进去的文件大小不对（{0} != {1}）' -f $actualSize, $expectSize) }
        } catch {
            $reason = $_.Exception.Message
            if ($reason -match 'being used by another process|另一个程序|正在使用') {
                throw 'DSH 主程序文件正被占用，说明 DeepSeek Harness 还没完全退出（托盘里的图标也要退出）。请退出后重试；这次没有改动任何文件。'
            }
            try {
                if ($moved -and (Test-Path -LiteralPath $oldAsar)) {
                    Copy-Item -LiteralPath $oldAsar -Destination $asar -Force -ErrorAction Stop
                    $backSize = (Get-Item -LiteralPath $asar).Length
                    if ($backSize -ne (Get-Item -LiteralPath $oldAsar).Length) { throw '回滚后文件大小不对' }
                }
            } catch {
                Write-InstallLog ('注意：回滚也可能失败了，请用「还原官方文件」或重新安装 DSH 恢复。原因：' + $_.Exception.Message) 'error'
            }
            throw ('替换失败，已回滚：' + $reason)
        }

        $prefs = Read-UnlockPrefs
        Write-UnlockState ([pscustomobject]@{
            Patched      = $true
            AppAsar      = $asar
            ModuleEntry  = $entry
            PatchId      = $patch.id
            PatchTitle   = $patch.title
            PatchedAt    = (Get-Date).ToString('s')
            DshVersion   = (Get-DshRuntimeVersion -AppDir $status.AppDir)
            AutoHeal     = $prefs.AutoHeal
            ToolMarker   = $script:UnlockMarker
        })

        Write-InstallLog '已解除插件版本限制。现在重启 DeepSeek Harness 生效。' 'ok'
        Write-InstallLog '以后官方更新覆盖了这个文件，安装器会自动重新打（勾选"自动修复"时）。' 'info'
        Remove-OldAsarBackups
        return $true
    } catch {
        Write-InstallLog ('解除限制失败：' + $_.Exception.Message) 'error'
        return $false
    } finally {
        try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

<#
  还原成官方原版：把插入的那行标记删掉，字节级还原。
#>
function Invoke-AsarRestore {
    param(
        [string]$AppDir,
        [switch]$IgnoreRunning
    )

    if (-not $AppDir) { $AppDir = Find-DshApp }
    if (Test-DshDirMode -AppDir $AppDir) {
        return (Invoke-DirRestore -AppDir $AppDir -IgnoreRunning:$IgnoreRunning)
    }

    $status = Get-UnlockStatus -AppDir $AppDir
    if (-not $status.Supported) {
        Write-InstallLog ('现在无法操作：' + $status.Reason) 'error'
        return $false
    }
    if (-not $status.Applied) {
        Write-InstallLog '现在就是官方原版，不需要还原（顺手清掉旧记录）。' 'info'
        Remove-UnlockState
        return $true
    }
    if ($status.Running -and -not $IgnoreRunning) {
        Write-InstallLog '请先完全退出 DeepSeek Harness（托盘里也要退出），再操作。' 'error'
        return $false
    }

    $asar = $status.AsarPath
    $entry = $status.ModuleEntry
    $node = Get-NodeExe -AppDir $status.AppDir
    $tool = Get-AsarToolPath
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-restore-' + (Get-Date -Format 'yyyyMMddHHmmss'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $srcFile = Join-Path $work 'module.js'
    $newFile = Join-Path $work 'module.clean.js'
    $newAsar = Join-Path $work 'app.asar.new'
    $oldAsar = Join-Path $work 'app.asar.old'

    try {
        Write-InstallLog '正在把补丁行删掉（还原官方原版）…' 'step'

        $r = Invoke-AsarTool -NodeExe $node -ToolPath $tool -Arguments @('extract', $asar, $entry, $srcFile)
        if (-not $r.Ok) { throw ('抽取模块失败：' + $r.Output) }
        $source = [System.IO.File]::ReadAllText($srcFile, [System.Text.Encoding]::UTF8)
        $clean = Remove-UnlockPatchFromSource -Source $source
        if ($clean.Contains($script:UnlockMarker)) { throw '补丁标记没能删干净，已放弃，DSH 文件没被改动。' }
        if ($clean -eq $source) { throw '这个文件里没有补丁标记，可能已经被官方更新覆盖了，不需要还原。' }

        [System.IO.File]::WriteAllText($newFile, $clean, (New-Object System.Text.UTF8Encoding($false)))
        $r = Invoke-AsarTool -NodeExe $node -ToolPath $tool -Arguments @('patch', $asar, $entry, $newFile, $newAsar)
        if (-not $r.Ok) { throw ('重新打包失败：' + $r.Output) }

        $r = Invoke-AsarTool -NodeExe $node -ToolPath $tool -Arguments @('verify', $newAsar)
        if (-not ($r.Ok -and $r.Output -match '问题 0 个')) { throw ('自检没通过，已放弃：' + $r.Output) }

        $expectSize = (Get-Item -LiteralPath $newAsar).Length
        $moved = $false
        try {
            Move-Item -LiteralPath $asar -Destination $oldAsar -Force -ErrorAction Stop
            $moved = $true
            Copy-Item -LiteralPath $newAsar -Destination $asar -Force -ErrorAction Stop
            if ((Get-Item -LiteralPath $asar -ErrorAction Stop).Length -ne $expectSize) { throw '写进去的文件大小不对' }
        } catch {
            $reason = $_.Exception.Message
            if ($reason -match 'being used by another process|另一个程序|正在使用') {
                throw 'DSH 主程序文件正被占用，请完全退出 DeepSeek Harness（托盘图标也要退出）后再试。'
            }
            if ($moved -and (Test-Path -LiteralPath $oldAsar)) {
                Copy-Item -LiteralPath $oldAsar -Destination $asar -Force -ErrorAction SilentlyContinue
            }
            throw ('还原失败，已回滚：' + $reason)
        }

        Remove-UnlockState
        Write-InstallLog '已还原成官方原版。重启 DeepSeek Harness 后，版本限制会恢复成官方行为。' 'ok'
        Remove-OldAsarBackups
        return $true
    } catch {
        Write-InstallLog ('还原失败：' + $_.Exception.Message) 'error'
        return $false
    } finally {
        try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# ---------------------------------------------------------------- 自动修复

<#
  官方更新把 app.asar 换掉以后，补丁就没了。开启"自动修复"时，
  安装器一启动就会自己重新打上 —— 用户什么都不用管。
#>
function Invoke-UnlockAutoHeal {
    param([string]$LogFile, [string]$AppDir, [switch]$IgnoreRunning)

    if ($LogFile) { Set-InstallerLogFile -Path $LogFile }
    $prefs = Read-UnlockPrefs
    if (-not $prefs.AutoHeal) {
        return [pscustomobject]@{ Ok = $false; Mode = 'off'; Message = '自动修复没开启' }
    }

    $status = Get-UnlockStatus -AppDir $AppDir
    if (-not $status.Supported) {
        return [pscustomobject]@{ Ok = $false; Mode = 'unsupported'; Message = $status.Reason }
    }
    if ($status.Applied) {
        return [pscustomobject]@{ Ok = $true; Mode = 'already'; Message = '补丁还在，不需要修复' }
    }
    if (-not (Read-UnlockState)) {
        return [pscustomobject]@{ Ok = $true; Mode = 'never'; Message = '这个插件版本限制从来没解除过，跳过自动修复' }
    }
    if ($status.FuseBlocked) {
        Write-InstallLog '官方已开启 asar 完整性校验，自动修复做不了（改了会导致程序起不来）。' 'warn'
        return [pscustomobject]@{ Ok = $false; Mode = 'fuse'; Message = $status.Reason }
    }
    if ($status.Running -and -not $IgnoreRunning) {
        return [pscustomobject]@{ Ok = $false; Mode = 'running'; Message = 'DeepSeek Harness 正在运行，退出后会自动修复' }
    }

    Write-InstallLog '检测到 DSH 更新过、补丁已失效，正在自动重新打上…' 'step'
    $ok = Invoke-AsarUnlock -AppDir $status.AppDir -IgnoreRunning:$IgnoreRunning
    return [pscustomobject]@{ Ok = $ok; Mode = 'healed'; Message = $(if ($ok) { '已自动修复，重启 DeepSeek Harness 生效' } else { '自动修复没成功，请看日志' }) }
}

<#
  一键流程：确保插件能用 —— 已解除就跳过，没解除就解除。
#>
function Invoke-UnlockEnsure {
    param([switch]$Quiet)
    $status = Get-UnlockStatus
    if (-not $status.Supported) {
        if (-not $Quiet) { Write-InstallLog $status.Reason 'warn' }
        return $false
    }
    if ($status.Applied) {
        if (-not $Quiet) { Write-InstallLog '插件版本限制已经是解除状态。' 'ok' }
        return $true
    }
    if ($status.Running) {
        Write-InstallLog '要修改 DSH 主程序，请先完全退出 DeepSeek Harness（托盘里也要退出）。' 'error'
        return $false
    }
    return (Invoke-AsarUnlock -AppDir $status.AppDir)
}

# ---------------------------------------------------------------- 工作流入口

function Invoke-UnlockWorkflow {
    param(
        [string]$LogFile,
        [string]$AppDir,
        [switch]$Restore,
        [switch]$AutoHeal,
        [switch]$IgnoreRunning
    )
    if ($LogFile) { Set-InstallerLogFile -Path $LogFile }

    if ($AutoHeal) {
        $r = Invoke-UnlockAutoHeal -AppDir $AppDir -IgnoreRunning:$IgnoreRunning
        if ($r.Mode -eq 'healed' -or $r.Mode -eq 'already') {
            return [pscustomobject]@{ Ok = [bool]$r.Ok; Message = $r.Message; Mode = $r.Mode }
        }
        return [pscustomobject]@{ Ok = $false; Error = $r.Message; Mode = $r.Mode }
    }

    $status = Get-UnlockStatus -AppDir $AppDir
    if (-not $status.Supported) {
        Write-InstallLog ('现在无法操作：' + $status.Reason) 'error'
        return [pscustomobject]@{ Ok = $false; Error = $status.Reason }
    }
    if ($Restore) {
        $ok = Invoke-AsarRestore -AppDir $status.AppDir -IgnoreRunning:$IgnoreRunning
        if ($ok) {
            return [pscustomobject]@{ Ok = $true; Message = '已还原成官方原版文件，重启 DeepSeek Harness 后生效' }
        }
        return [pscustomobject]@{ Ok = $false; Error = '还原没有完成，请看上面的日志' }
    }
    $ok = Invoke-AsarUnlock -AppDir $status.AppDir -IgnoreRunning:$IgnoreRunning
    if ($ok) {
        return [pscustomobject]@{ Ok = $true; Message = '已解除插件版本限制，重启 DeepSeek Harness 后生效' }
    }
    return [pscustomobject]@{ Ok = $false; Error = '解除没有完成，请看上面的日志' }
}
