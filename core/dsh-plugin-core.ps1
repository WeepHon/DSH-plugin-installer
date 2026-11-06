<#
  dsh-plugin-core.ps1
  ------------------------------------------------------------------
  DSH 插件安装器 · 核心引擎（不依赖 DSH 运行，纯文件操作 + 官方 CLI）

  设计原则:
    1. 优先走 DSH 自带命令 (resources\runtime\cli\bin\dsh.cmd plugin add)，
       与官方"插件"页面的安装结果完全一致（依赖记录 / bundles 激活 / node_modules）。
    2. 找不到命令行时，退化到"备用模式"：直接写 profile 的 package.json、
       dsh.profile.bundles，并在 node_modules 下建目录联接（Junction）。
    3. 任何改动前都备份，任何改动都能回滚。

  兼容 Windows PowerShell 5.1（不要用 PS7 专有语法）。
#>

$script:CoreDir = $PSScriptRoot
$script:InstallerRoot = Split-Path -Parent $PSScriptRoot
$script:LogFile = $null
$script:BackupRoot = $null

# ------------------------------------------------------------------ 日志

function Set-InstallerLogFile {
    param([string]$Path)
    $script:LogFile = $Path
    if ($Path) {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        [System.IO.File]::WriteAllText($Path, '', (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Write-InstallLog {
    param([string]$Message, [string]$Level = 'info')
    $prefix = '[{0}] ' -f (Get-Date -Format 'HH:mm:ss')
    if ($Level -eq 'error') { $prefix += '× ' }
    elseif ($Level -eq 'warn') { $prefix += '! ' }
    elseif ($Level -eq 'ok') { $prefix += '√ ' }
    elseif ($Level -eq 'step') { $prefix += '» ' }
    $line = $prefix + $Message
    if ($script:LogFile) {
        try { [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch { }
    }
    Write-Host $line
}

# ------------------------------------------------------------------ 环境探测

function Get-DshHomePath {
    if ($env:DSH_HOME -and $env:DSH_HOME.Trim().Length -gt 0) { return $env:DSH_HOME }
    return (Join-Path $HOME '.dsh')
}

function Get-DshProfilesRoot {
    return (Join-Path (Get-DshHomePath) 'profiles')
}

<#
  找桌面版 DeepSeek Harness 的安装目录（含 resources\runtime\cli\bin\dsh.cmd）。
#>
function Find-DshApp {
    $candidates = New-Object System.Collections.ArrayList
    if ($env:DSH_APP_DIR) { [void]$candidates.Add($env:DSH_APP_DIR) }
    if ($env:LOCALAPPDATA) { [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness')) }
    if (${env:ProgramFiles}) { [void]$candidates.Add((Join-Path ${env:ProgramFiles} 'DeepSeek Harness')) }
    if (${env:ProgramFiles(x86)}) { [void]$candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness')) }
    foreach ($drive in @('D:\', 'C:\', 'E:\')) {
        [void]$candidates.Add(($drive + 'DSH'))
        [void]$candidates.Add(($drive + 'DeepSeek Harness'))
    }
    # 注册表卸载项
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($key in $uninstallKeys) {
        try {
            Get-ItemProperty -Path $key -ErrorAction Stop |
                Where-Object { $_.DisplayName -like '*DeepSeek Harness*' -or $_.DisplayName -like '*DSH*' } |
                ForEach-Object {
                    if ($_.InstallLocation) { [void]$candidates.Add($_.InstallLocation) }
                }
        } catch { }
    }
    # 正在运行的进程（若已打开）
    try {
        Get-Process -Name 'DeepSeek Harness' -ErrorAction Stop | ForEach-Object {
            if ($_.Path) { [void]$candidates.Add((Split-Path -Parent $_.Path)) }
        }
    } catch { }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $cli = Join-Path $c 'resources\runtime\cli\bin\dsh.cmd'
        if (Test-Path -LiteralPath $cli) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    return $null
}

<#
  返回可用的 DSH 命令行:
    @{ Kind = 'desktop' | 'npm'; Path = '...dsh.cmd'; AppDir = ... }
#>
function Find-DshCli {
    $app = Find-DshApp
    if ($app) {
        return [pscustomobject]@{
            Kind   = 'desktop'
            Path   = (Join-Path $app 'resources\runtime\cli\bin\dsh.cmd')
            AppDir = $app
        }
    }
    $npmCli = Get-Command 'dsh.cmd' -ErrorAction SilentlyContinue
    if (-not $npmCli) { $npmCli = Get-Command 'dsh' -ErrorAction SilentlyContinue }
    if ($npmCli) {
        return [pscustomobject]@{
            Kind   = 'npm'
            Path   = $npmCli.Source
            AppDir = $null
        }
    }
    return $null
}

function Get-DshRuntimeVersion {
    param($Cli)
    if (-not $Cli) { $Cli = Find-DshCli }
    if (-not $Cli) { return $null }
    try {
        $v = & $Cli.Path --version 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        foreach ($line in @($v)) {
            $text = ([string]$line).Trim()
            if ($text -match '^\d+\.\d+') { return $text }
        }
    } catch { }
    return $null
}

function Test-DshDesktopRunning {
    try {
        $p = Get-Process -Name 'DeepSeek Harness' -ErrorAction Stop
        return (@($p).Count -gt 0)
    } catch {
        return $false
    }
}

<#
  列出已初始化的 profile（有 package.json 的目录）。
#>
function Get-DshProfiles {
    $root = Get-DshProfilesRoot
    $list = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $pkg = Join-Path $_.FullName 'package.json'
        $initialized = Test-Path -LiteralPath $pkg
        $name = $_.Name
        $count = 0
        if ($initialized) {
            try {
                $j = Get-Content -LiteralPath $pkg -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($j.dependencies) { $count = @($j.dependencies.PSObject.Properties).Count }
            } catch { }
        }
        [void]$list.Add([pscustomobject]@{
            Name        = $name
            Dir         = $_.FullName
            Initialized = $initialized
            DependencyCount = $count
        })
    }
    return $list.ToArray()
}

function Get-DshProfileInfo {
    param([string]$Name)
    $dir = Join-Path (Get-DshProfilesRoot) $Name
    return [pscustomobject]@{
        Name        = $Name
        Dir         = $dir
        Initialized = (Test-Path -LiteralPath (Join-Path $dir 'package.json'))
    }
}

# ------------------------------------------------------------------ 版本范围比对

function ConvertTo-SemVerParts {
    param([string]$Version)
    if (-not $Version) { return $null }
    $m = [regex]::Match($Version.Trim(), '^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z\.\-]+))?(?:\+.*)?$')
    if (-not $m.Success) { return $null }
    $major = [int]$m.Groups[1].Value
    $minor = 0; $patch = 0
    if ($m.Groups[2].Success -and $m.Groups[2].Value) { $minor = [int]$m.Groups[2].Value }
    if ($m.Groups[3].Success -and $m.Groups[3].Value) { $patch = [int]$m.Groups[3].Value }
    $pre = ''
    if ($m.Groups[4].Success) { $pre = $m.Groups[4].Value }
    return [pscustomobject]@{ Major = $major; Minor = $minor; Patch = $patch; Pre = $pre }
}

function Compare-SemVer {
    param([string]$Left, [string]$Right)
    $a = ConvertTo-SemVerParts $Left
    $b = ConvertTo-SemVerParts $Right
    if (-not $a -or -not $b) { return 0 }
    if ($a.Major -ne $b.Major) { return ($a.Major - $b.Major) }
    if ($a.Minor -ne $b.Minor) { return ($a.Minor - $b.Minor) }
    if ($a.Patch -ne $b.Patch) { return ($a.Patch - $b.Patch) }
    if ($a.Pre -eq $b.Pre) { return 0 }
    if ($a.Pre -eq '') { return 1 }      # 有正式版 > 有预发布
    if ($b.Pre -eq '') { return -1 }
    $ap = $a.Pre.Split('.')
    $bp = $b.Pre.Split('.')
    $len = [Math]::Min($ap.Length, $bp.Length)
    for ($i = 0; $i -lt $len; $i++) {
        $x = $ap[$i]; $y = $bp[$i]
        $xn = 0; $yn = 0
        $xIsNum = [int]::TryParse($x, [ref]$xn)
        $yIsNum = [int]::TryParse($y, [ref]$yn)
        if ($xIsNum -and $yIsNum) {
            if ($xn -ne $yn) { return ($xn - $yn) }
        } elseif ($xIsNum) {
            return -1
        } elseif ($yIsNum) {
            return 1
        } else {
            $c = [string]::CompareOrdinal($x, $y)
            if ($c -ne 0) { return $c }
        }
    }
    return ($ap.Length - $bp.Length)
}

<#
  判断 version 是否落在 range 内。支持 ">=a <b"、"a || b"、"=a"，以及单版本号。
  无法识别的写法（^ ~ * x）返回 $true 并标记 Unknown，由上层给出提示。
#>
function Test-SemVerRange {
    param([string]$Version, [string]$Range)
    $result = [pscustomobject]@{ InRange = $true; Unknown = $false }
    if (-not $Range -or $Range.Trim().Length -eq 0) { return $result }
    if (-not (ConvertTo-SemVerParts $Version)) { $result.Unknown = $true; return $result }
    $clauses = $Range -split '\|\|'
    $anyMatched = $false
    $anyKnown = $false
    foreach ($clause in $clauses) {
        $text = $clause.Trim()
        if ($text.Length -eq 0) { continue }
        if ($text -match '(^|[\s(])(\^|~|\*|x|X)') { continue }   # 不支持的范围写法
        $tokens = [regex]::Matches($text, '(>=|<=|>|<|=)?\s*([0-9][0-9A-Za-z\.\-]*)')
        if ($tokens.Count -eq 0) { continue }
        $ok = $true
        $known = $false
        foreach ($t in $tokens) {
            $op = $t.Groups[1].Value
            if (-not $op) { $op = '=' }
            $rhs = $t.Groups[2].Value
            if (-not (ConvertTo-SemVerParts $rhs)) { continue }
            $known = $true
            $c = Compare-SemVer $Version $rhs
            switch ($op) {
                '>=' { if ($c -lt 0) { $ok = $false } }
                '<=' { if ($c -gt 0) { $ok = $false } }
                '>'  { if ($c -le 0) { $ok = $false } }
                '<'  { if ($c -ge 0) { $ok = $false } }
                '='  { if ($c -ne 0) { $ok = $false } }
            }
        }
        if (-not $known) { continue }
        $anyKnown = $true
        if ($ok) { $anyMatched = $true }
    }
    if (-not $anyKnown) { $result.Unknown = $true; return $result }
    $result.InRange = $anyMatched
    return $result
}

# ------------------------------------------------------------------ 插件包解析

<#
  把用户给的东西变成"插件目录"：
    目录 -> 直接用；.zip -> 解压到临时目录，找到含 package.json 的那一层。
#>
function Resolve-PluginSource {
    param([string]$Path)
    if (-not $Path) { throw '请先选择插件文件夹或压缩包。' }
    $p = $Path.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $p)) { throw "路径不存在：$p" }
    $item = Get-Item -LiteralPath $p
    if ($item.PSIsContainer) {
        if (Test-Path -LiteralPath (Join-Path $item.FullName 'package.json')) { return $item.FullName }
        # 允许选择"外层文件夹"，自动下探一层
        $inner = Get-ChildItem -LiteralPath $item.FullName -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'package.json') }
        if (@($inner).Count -eq 1) { return $inner[0].FullName }
        throw "这个文件夹里没有 package.json，不像是 DSH 插件：$($item.FullName)"
    }
    if ($item.Extension -ieq '.zip') {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-plugin-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $temp | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::ExtractToDirectory($item.FullName, $temp)
        $found = @(Get-ChildItem -LiteralPath $temp -Recurse -Depth 2 -Filter 'package.json' -File -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) { throw '压缩包里没有找到 package.json。' }
        $best = $found | Sort-Object { $_.FullName.Length } | Select-Object -First 1
        return (Split-Path -Parent $best.FullName)
    }
    throw "看不懂这个路径：$p（请选择插件文件夹或 .zip）"
}

function Get-PatchInsertIds {
    param([string]$PatchPath)
    $ids = New-Object System.Collections.ArrayList
    if (-not $PatchPath -or -not (Test-Path -LiteralPath $PatchPath)) { return @() }
    $inInsert = $false
    foreach ($raw in (Get-Content -LiteralPath $PatchPath -ErrorAction SilentlyContinue)) {
        $line = ([string]$raw).TrimEnd()
        if ($line -match '^\s*#' -or $line.Trim().Length -eq 0) { continue }
        if ($line -match '^\-\s*insert:\s*$') { $inInsert = $true; continue }
        if ($line -match '^\-') { $inInsert = $false; continue }
        if (-not $inInsert) { continue }
        $m = [regex]::Match($line, '^\s*\-\s*id:\s*(.+?)\s*$')
        if ($m.Success) {
            $id = $m.Groups[1].Value.Trim()
            $id = $id -replace "^['""]", '' -replace "['""]$", ''
            [void]$ids.Add($id)
        }
    }
    return $ids.ToArray()
}

<#
  读取并校验插件包信息。
#>
function Read-PluginInfo {
    param([string]$Dir)
    $pkgPath = Join-Path $Dir 'package.json'
    if (-not (Test-Path -LiteralPath $pkgPath)) { throw "缺少 package.json：$Dir" }
    try {
        $json = Get-Content -LiteralPath $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "package.json 不是合法的 JSON：$pkgPath"
    }
    if (-not $json.name) { throw 'package.json 里缺少 name 字段。' }
    if (-not ([string]$json.name -match '^(@[A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+$')) {
        throw "插件名 '$($json.name)' 看起来不合法。"
    }
    $version = if ($json.version) { [string]$json.version } else { '0.0.0' }
    $engineRange = ''
    if ($json.engines -and $json.engines.dsh) { $engineRange = [string]$json.engines.dsh }

    $patchPath = $null
    $hasBundle = $false
    if ($json.dsh -and $json.dsh.bundle -and $json.dsh.bundle.patch) {
        $hasBundle = $true
        $patchPath = Join-Path $Dir ([string]$json.dsh.bundle.patch)
    }
    $hasClient = $false
    if ($json.dsh -and $json.dsh.client) { $hasClient = $true }

    $mainOk = $true
    if ($json.main) {
        $mainOk = Test-Path -LiteralPath (Join-Path $Dir ([string]$json.main))
    }

    return [pscustomobject]@{
        Name         = [string]$json.name
        Version      = $version
        Description  = if ($json.description) { [string]$json.description } else { '' }
        EngineRange  = $engineRange
        HasBundle    = $hasBundle
        PatchPath    = $patchPath
        PatchExists  = if ($patchPath) { Test-Path -LiteralPath $patchPath } else { $false }
        InsertIds    = if ($patchPath) { Get-PatchInsertIds -PatchPath $patchPath } else { @() }
        HasClient    = $hasClient
        MainOk       = $mainOk
        Dir          = $Dir
        PackageJson  = $json
    }
}

<#
  在当前机器可发现的候选插件（plugins 目录 / 桌面 / 下载）。
#>
function Find-CandidatePlugins {
    $roots = @(
        (Join-Path $script:InstallerRoot 'plugins'),
        (Join-Path $HOME 'Desktop'),
        (Join-Path $HOME 'Downloads')
    )
    $seen = @{}
    $list = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $dirs = @()
        if ((Split-Path -Leaf $root) -eq 'plugins') {
            $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)
            $dirs += @(Get-ChildItem -LiteralPath $root -File -Filter '*.zip' -ErrorAction SilentlyContinue)
        } else {
            $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*dsh*' -or $_.Name -like '*plugin*' })
        }
        foreach ($d in $dirs) {
            try {
                $src = Resolve-PluginSource -Path $d.FullName
                $info = Read-PluginInfo -Dir $src
                $key = $info.Name + '@' + $info.Version
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                [void]$list.Add([pscustomobject]@{
                    Path    = $src
                    Name    = $info.Name
                    Version = $info.Version
                    Label   = ('{0}  v{1}   ({2})' -f $info.Name, $info.Version, (Split-Path -Leaf $src))
                })
            } catch { }
        }
    }
    return $list.ToArray()
}

# ------------------------------------------------------------------ 备份

function Get-BackupDir {
    param([string]$ProfileDir)
    if (-not $script:BackupRoot) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $script:BackupRoot = Join-Path (Join-Path (Get-DshHomePath) 'plugin-installer-backups') $stamp
    }
    $dir = Join-Path $script:BackupRoot $ProfileDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Backup-ProfileFile {
    param([string]$ProfileDir, [string]$FileName)
    $src = Join-Path $ProfileDir $FileName
    if (-not (Test-Path -LiteralPath $src)) { return $null }
    $destDir = Get-BackupDir -ProfileDir (Split-Path -Leaf $ProfileDir)
    $dest = Join-Path $destDir $FileName
    Copy-Item -LiteralPath $src -Destination $dest -Force
    return $dest
}

# ------------------------------------------------------------------ 版本豁免

<#
  DSH 的"插件兼容性"只有一道判定：插件 package.json 里的 engines.dsh（以及 peer 依赖）
  与当前 DSH 版本是否匹配。不匹配时 DSH 启动阶段会直接把这一行 disabled 掉。
  唯一官方认可的解法是给"具体的 name@version + 具体的 DSH 版本"开一条豁免，记录在
  profiles\<名字>\compatibility.json 里，形如：
      { "dsh-unrestricted@0.2.4": ["0.2.0-rc.2"] }
  这个文件是 profile 自己的元数据，不联网、也不需要签名，直接写就行。
  官方命令 dsh plugin allow-version 写的就是它；这里直写一份，保证
  没有命令行（npm 版 dsh / 备用模式）时也能生效。
#>

function Get-ProfileCompatibilityPath {
    param([string]$ProfileName)
    return (Join-Path (Join-Path (Get-DshProfilesRoot) $ProfileName) 'compatibility.json')
}

function Get-ProfileVersionExemptions {
    param([string]$ProfileName)
    $path = Get-ProfileCompatibilityPath -ProfileName $ProfileName
    $result = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $result }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if (-not $raw.Trim()) { return $result }
        $parsed = $raw | ConvertFrom-Json
        foreach ($prop in $parsed.PSObject.Properties) {
            $list = @()
            foreach ($v in @($prop.Value)) { $list += [string]$v }
            $result[$prop.Name] = $list
        }
    } catch {
        Write-InstallLog ('compatibility.json 读不出来，将重新整理：' + $_.Exception.Message) 'warn'
    }
    return $result
}

<#
  给某个 插件@版本 开一条"允许在指定 DSH 版本上运行"的豁免。
  已存在则保留原内容，只补一条，不会覆盖用户手工加的其它条目。
#>
function Add-ProfileVersionExemption {
    param(
        [string]$ProfileName,
        [string]$PackageName,
        [string]$PackageVersion,
        [string]$RuntimeVersion
    )
    if (-not $ProfileName -or -not $PackageName -or -not $PackageVersion -or -not $RuntimeVersion) {
        throw '版本豁免参数不完整。'
    }
    $path = Get-ProfileCompatibilityPath -ProfileName $ProfileName
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path -LiteralPath $path) { [void](Backup-ProfileFile -ProfileDir $dir -FileName 'compatibility.json') }

    $key = $PackageName + '@' + $PackageVersion
    $data = Get-ProfileVersionExemptions -ProfileName $ProfileName
    $versions = @()
    if ($data.ContainsKey($key)) { $versions = @($data[$key]) }
    if ($versions -notcontains $RuntimeVersion) { $versions += $RuntimeVersion }

    $out = [ordered]@{}
    foreach ($k in $data.Keys) { if ($k -ne $key) { $out[$k] = @($data[$k]) } }
    $out[$key] = @($versions)

    # 手写一份整洁的 JSON（ConvertTo-Json 会把数组对齐得很丑）
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("{`r`n")
    $keys = @($out.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $k = $keys[$i]
        $vals = @($out[$k])
        [void]$sb.Append('  "' + $k + '": [')
        for ($j = 0; $j -lt $vals.Count; $j++) {
            [void]$sb.Append('"' + $vals[$j] + '"')
            if ($j -lt $vals.Count - 1) { [void]$sb.Append(', ') }
        }
        [void]$sb.Append(']')
        if ($i -lt $keys.Count - 1) { [void]$sb.Append(',') }
        [void]$sb.Append("`r`n")
    }
    [void]$sb.Append("}`r`n")
    [System.IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Write-InstallLog ('已写入版本豁免：' + $key + ' 允许在 DSH ' + $RuntimeVersion + ' 上运行（' + $path + '）') 'warn'
    return $path
}

function Test-ProfileVersionExemption {
    param([string]$ProfileName, [string]$PackageName, [string]$PackageVersion, [string]$RuntimeVersion)
    $key = $PackageName + '@' + $PackageVersion
    $data = Get-ProfileVersionExemptions -ProfileName $ProfileName
    if (-not $data.ContainsKey($key)) { return $false }
    return (@($data[$key]) -contains $RuntimeVersion)
}
# ------------------------------------------------------------------ 本地插件仓

<#
  把插件复制到 %USERPROFILE%\.dsh\local-plugins\<name>-<version>，
  这样桌面上的源文件夹可以随便删。
#>
function Publish-PluginCopy {
    param([string]$SourceDir, $Info)
    $root = Join-Path (Get-DshHomePath) 'local-plugins'
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
    $dest = Join-Path $root ('{0}-{1}' -f ($Info.Name -replace '[/\\]', '__'), $Info.Version)

    $srcFull = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd('\')
    $destFull = [System.IO.Path]::GetFullPath($dest).TrimEnd('\')
    if ($srcFull -ieq $destFull) {
        Write-InstallLog "插件已在本地仓库，跳过复制：$dest" 'ok'
        return $dest
    }
    if (Test-Path -LiteralPath $dest) {
        Write-InstallLog "刷新本地仓库副本：$dest"
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $exclude = @('node_modules', '.git')
    Get-ChildItem -LiteralPath $srcFull -Force | Where-Object { $exclude -notcontains $_.Name } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
    }
    Write-InstallLog "已复制插件到本地仓库：$dest" 'ok'
    return $dest
}

# ------------------------------------------------------------------ 官方 CLI 调用

function Invoke-DshPluginCli {
    param($Cli, [string]$ProfileName, [string[]]$Arguments)
    $argv = @('plugin', '--profile', $ProfileName) + $Arguments
    Write-InstallLog ('执行："{0}" {1}' -f $Cli.Path, ($argv -join ' '))
    $captured = @()
    try {
        $captured = & $Cli.Path @argv 2>&1
        $code = $LASTEXITCODE
    } catch {
        Write-InstallLog ("命令执行失败：" + $_.Exception.Message) 'error'
        return [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message }
    }
    foreach ($line in @($captured)) {
        $text = ([string]$line).TrimEnd()
        if ($text.Length -gt 0) { Write-InstallLog ('   ' + $text) }
    }
    return [pscustomobject]@{ ExitCode = $code; Output = (@($captured) | Out-String) }
}

# ------------------------------------------------------------------ profile 清单读写

function Read-ProfileManifest {
    param([string]$ProfileDir)
    $pkg = Join-Path $ProfileDir 'package.json'
    if (-not (Test-Path -LiteralPath $pkg)) { throw "配置目录尚未初始化（缺少 package.json）：$ProfileDir" }
    return (Get-Content -LiteralPath $pkg -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-ProfileManifest {
    param([string]$ProfileDir, $Manifest)
    $pkg = Join-Path $ProfileDir 'package.json'
    $json = $Manifest | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($pkg, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ProfileBundleList {
    param($Manifest)
    if ($Manifest.dsh -and $Manifest.dsh.profile -and $Manifest.dsh.profile.bundles) {
        return @($Manifest.dsh.profile.bundles)
    }
    return @()
}

# ------------------------------------------------------------------ 备用（手工）模式

function Install-PluginManual {
    param($Info, [string]$ProfileName, [string]$PluginCopyDir)
    $profile = Get-DshProfileInfo -Name $ProfileName
    if (-not $profile.Initialized) {
        throw "「$ProfileName」配置还没初始化。请先启动一次 DSH（或运行官方命令行初始化），再来安装。"
    }
    Write-InstallLog "备用模式：直接修改 $($profile.Dir)" 'warn'
    $backup = Backup-ProfileFile -ProfileDir $profile.Dir -FileName 'package.json'
    if ($backup) { Write-InstallLog "已备份 package.json 到：$backup" }

    $manifest = Read-ProfileManifest -ProfileDir $profile.Dir

    # 1) 依赖
    $deps = @{}
    if ($manifest.dependencies) {
        foreach ($p in $manifest.dependencies.PSObject.Properties) { $deps[$p.Name] = $p.Value }
    }
    $spec = 'file:' + ($PluginCopyDir -replace '\\', '/')
    $deps[$Info.Name] = $spec
    $depObject = [pscustomobject]$deps
    if ($manifest.PSObject.Properties['dependencies']) { $manifest.dependencies = $depObject }
    else { $manifest | Add-Member -MemberType NoteProperty -Name dependencies -Value $depObject }

    # 2) bundles
    $bundles = New-Object System.Collections.ArrayList
    foreach ($b in (Get-ProfileBundleList $manifest)) { [void]$bundles.Add($b) }
    if (-not $bundles.Contains($Info.Name)) { [void]$bundles.Add($Info.Name) }
    $bundleArray = $bundles.ToArray()
    if (-not ($manifest.PSObject.Properties['dsh'])) {
        $manifest | Add-Member -MemberType NoteProperty -Name dsh -Value ([pscustomobject]@{})
    }
    if (-not ($manifest.dsh.PSObject.Properties['profile'])) {
        $manifest.dsh | Add-Member -MemberType NoteProperty -Name profile -Value ([pscustomobject]@{})
    }
    if ($manifest.dsh.profile.PSObject.Properties['bundles']) { $manifest.dsh.profile.bundles = $bundleArray }
    else { $manifest.dsh.profile | Add-Member -MemberType NoteProperty -Name bundles -Value $bundleArray }

    Write-ProfileManifest -ProfileDir $profile.Dir -Manifest $manifest
    Write-InstallLog "已写入依赖与 bundles 列表" 'ok'

    # 3) node_modules 目录联接
    $nm = Join-Path $profile.Dir 'node_modules'
    if (-not (Test-Path -LiteralPath $nm)) { New-Item -ItemType Directory -Force -Path $nm | Out-Null }
    $linkPath = Join-Path $nm $Info.Name
    $parent = Split-Path -Parent $linkPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (Test-Path -LiteralPath $linkPath) {
        $existing = Get-Item -LiteralPath $linkPath -Force
        if ($existing.LinkType) { $existing.Delete() } else { Remove-Item -LiteralPath $linkPath -Recurse -Force }
    }
    try {
        New-Item -ItemType Junction -Path $linkPath -Target $PluginCopyDir | Out-Null
        Write-InstallLog "已在 node_modules 建立联接：$linkPath" 'ok'
    } catch {
        # 退化为复制
        Copy-Item -LiteralPath $PluginCopyDir -Destination $linkPath -Recurse -Force
        Write-InstallLog "联接失败，已改为复制文件：$($_.Exception.Message)" 'warn'
    }
}

function Uninstall-PluginManual {
    param([string]$PluginName, [string]$ProfileName)
    $profile = Get-DshProfileInfo -Name $ProfileName
    if (-not $profile.Initialized) { return '配置未初始化，跳过' }
    Backup-ProfileFile -ProfileDir $profile.Dir -FileName 'package.json' | Out-Null
    $manifest = Read-ProfileManifest -ProfileDir $profile.Dir
    $deps = @{}
    if ($manifest.dependencies) {
        foreach ($p in $manifest.dependencies.PSObject.Properties) {
            if ($p.Name -ne $PluginName) { $deps[$p.Name] = $p.Value }
        }
    }
    if ($manifest.PSObject.Properties['dependencies']) { $manifest.dependencies = [pscustomobject]$deps }
    $bundles = @(Get-ProfileBundleList $manifest | Where-Object { $_ -ne $PluginName })
    if ($manifest.dsh -and $manifest.dsh.profile -and $manifest.dsh.profile.PSObject.Properties['bundles']) {
        $manifest.dsh.profile.bundles = $bundles
    }
    Write-ProfileManifest -ProfileDir $profile.Dir -Manifest $manifest
    $linkPath = Join-Path (Join-Path $profile.Dir 'node_modules') $PluginName
    if (Test-Path -LiteralPath $linkPath) {
        $existing = Get-Item -LiteralPath $linkPath -Force
        if ($existing.LinkType) { $existing.Delete() } else { Remove-Item -LiteralPath $linkPath -Recurse -Force }
    }
    return '已从依赖、bundles、node_modules 中移除'
}

# ------------------------------------------------------------------ cordis.patch.yml 开关

function Add-ProfilePatchEntry {
    param($Info, [string]$ProfileName)
    $profile = Get-DshProfileInfo -Name $ProfileName
    if (-not $profile.Initialized) { return '配置未初始化，跳过开关写入' }
    $patchPath = Join-Path $profile.Dir 'cordis.patch.yml'
    Backup-ProfileFile -ProfileDir $profile.Dir -FileName 'cordis.patch.yml' | Out-Null

    $lines = @()
    if (Test-Path -LiteralPath $patchPath) {
        $lines = @(Get-Content -LiteralPath $patchPath)
    } else {
        $lines = @('# 由 DSH 插件安装器创建：插件功能开关')
    }
    $text = ($lines -join "`n")

    $ids = @($Info.InsertIds)
    if (@($ids).Count -eq 0) { $ids = @($Info.Name) }

    $added = @()
    foreach ($id in $ids) {
        if (-not $id) { continue }
        if ($text -match ('(?m)^\s*\-\s*id:\s*' + [regex]::Escape($id) + '\s*$')) {
            Write-InstallLog "cordis.patch.yml 里已存在 id=$id 的配置行，保留用户设置" 'ok'
            continue
        }
        $lines += ''
        $lines += '# dsh-plugin-installer: auto-enable ' + $Info.Name
        $lines += ('- id: ' + $id)
        $lines += '  config:'
        $lines += '    enabled: true'
        $added += $id
    }
    if (@($added).Count -gt 0) {
        $out = ($lines -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($patchPath, $out, (New-Object System.Text.UTF8Encoding($false)))
        Write-InstallLog ("已写入插件开关：" + ($added -join ', ')) 'ok'
    }
    return ($added -join ', ')
}

function Remove-ProfilePatchEntry {
    param([string]$PluginName, [string]$ProfileName)
    $profile = Get-DshProfileInfo -Name $ProfileName
    $patchPath = Join-Path $profile.Dir 'cordis.patch.yml'
    if (-not (Test-Path -LiteralPath $patchPath)) { return }
    $lines = @(Get-Content -LiteralPath $patchPath)
    $marker = '# dsh-plugin-installer: auto-enable ' + $PluginName
    $out = New-Object System.Collections.ArrayList
    $skip = $false
    $removed = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if ($line.Trim() -eq $marker) { $skip = $true; $removed++; continue }
        if ($skip) {
            if ($line -match '^\s*-\s*id:') { continue }
            if ($line -match '^\s+name:') { continue }
            if ($line -match '^\s*config:\s*$') { continue }
            if ($line -match '^\s+enabled:\s*(true|false)\s*$') { continue }
            if ($line.Trim().Length -eq 0) { continue }
            $skip = $false
        }
        if ($line.Trim().Length -eq 0 -and $out.Count -gt 0 -and ([string]$out[$out.Count - 1]).Trim().Length -eq 0) { continue }
        [void]$out.Add($line)
    }
    if ($removed -gt 0) {
        Backup-ProfileFile -ProfileDir $profile.Dir -FileName 'cordis.patch.yml' | Out-Null
        [System.IO.File]::WriteAllText($patchPath, (($out -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-InstallLog "已移除安装器写入的插件开关" 'ok'
    }
}

# ------------------------------------------------------------------ 安装状态

function Get-PluginInstallState {
    param([string]$PluginName, [string]$ProfileName)
    $profile = Get-DshProfileInfo -Name $ProfileName
    $state = [pscustomobject]@{
        Profile    = $ProfileName
        Initialized = $profile.Initialized
        Declared   = $false
        Spec       = ''
        InBundles  = $false
        InNodeModules = $false
        InstalledVersion = ''
    }
    if (-not $profile.Initialized) { return $state }
    try {
        $manifest = Read-ProfileManifest -ProfileDir $profile.Dir
    } catch { return $state }
    if ($manifest.dependencies -and $manifest.dependencies.PSObject.Properties[$PluginName]) {
        $state.Declared = $true
        $state.Spec = [string]$manifest.dependencies.PSObject.Properties[$PluginName].Value
    }
    $state.InBundles = (@(Get-ProfileBundleList $manifest) -contains $PluginName)
    $nmPkg = Join-Path (Join-Path $profile.Dir 'node_modules') (Join-Path $PluginName 'package.json')
    if (Test-Path -LiteralPath $nmPkg) {
        $state.InNodeModules = $true
        try {
            $j = Get-Content -LiteralPath $nmPkg -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.version) { $state.InstalledVersion = [string]$j.version }
        } catch { }
    }
    return $state
}

# ------------------------------------------------------------------ 工作流：安装

function Invoke-InstallWorkflow {
    param(
        [string]$PluginPath,
        [string[]]$Profiles = @(),
        [bool]$EnableConfig = $false,
        [bool]$ForceVersion = $false,
        [bool]$ManualMode = $false,
        [string]$LogFile = $null
    )
    if ($LogFile) { Set-InstallerLogFile -Path $LogFile }
    $report = [ordered]@{
        Ok       = $false
        Title    = ''
        Message  = ''
        Profiles = @()
        Error    = ''
        LogFile  = $LogFile
    }
    try {
        $cli = Find-DshCli
        $runtime = Get-DshRuntimeVersion -Cli $cli
        Write-InstallLog '===== 开始安装 =====' 'step'
        Write-InstallLog ('DSH 主目录：' + (Get-DshHomePath))
        if ($cli) { Write-InstallLog ('命令行工具：' + $cli.Path + '（' + $cli.Kind + '）') }
        Write-InstallLog ('DSH 版本：' + $(if ($runtime) { $runtime } else { '未知' }))

        $source = Resolve-PluginSource -Path $PluginPath
        $info = Read-PluginInfo -Dir $source
        $report.Title = ('{0} v{1}' -f $info.Name, $info.Version)
        Write-InstallLog ('插件：' + $info.Name + ' v' + $info.Version)
        if ($info.Description) { Write-InstallLog ('说明：' + $info.Description) }

        if (-not $info.MainOk) { Write-InstallLog '警告：package.json 里的 main 文件不存在，插件可能加载失败' 'warn' }
        if ($info.HasBundle -and -not $info.PatchExists) {
            throw ('插件声明了 bundle patch（' + $info.PackageJson.dsh.bundle.patch + '），但文件不存在。')
        }

        # 兼容性
        $compatible = $true
        if ($info.EngineRange -and $runtime) {
            $check = Test-SemVerRange -Version $runtime -Range $info.EngineRange
            if ($check.Unknown) {
                Write-InstallLog ('无法解析版本要求 "' + $info.EngineRange + '"，跳过检查') 'warn'
            } elseif (-not $check.InRange) {
                $compatible = $false
                Write-InstallLog ('版本不兼容：插件要求 DSH ' + $info.EngineRange + '，当前 ' + $runtime) 'warn'
            } else {
                Write-InstallLog ('版本兼容：要求 ' + $info.EngineRange + '，当前 ' + $runtime) 'ok'
            }
        }

        if (@($Profiles).Count -eq 0) { throw '请至少选择一个安装目标（桌面版 / Web 版）。' }

        # 复制到本地仓库，源目录可随意删除
        $copy = Publish-PluginCopy -SourceDir $source -Info $info

        foreach ($profileName in $Profiles) {
            Write-InstallLog ('----- 目标：' + $profileName + ' -----', 'step')
            $profile = Get-DshProfileInfo -Name $profileName
            if (-not $profile.Initialized) {
                if ($ManualMode) {
                    throw ('「' + $profileName + '」配置尚未初始化。请先启动一次 DSH 完成初始化（桌面版装过一次即可）。')
                }
                Write-InstallLog ('「' + $profileName + '」配置尚未初始化，将由官方命令行自动创建。') 'warn'
            }

            $installOk = $false
            if (-not $ManualMode) {
                if (-not $cli) { throw '找不到 DSH 命令行工具，无法使用官方安装通道。请勾选"备用安装模式"。' }
                if ($cli.Kind -eq 'npm' -and -not (Get-Command 'pnpm' -ErrorAction SilentlyContinue)) {
                    throw '当前用的是 npm 安装的 dsh，但没有检测到 pnpm。建议改用桌面版自带的命令行，或先安装 pnpm。'
                }
                if (-not $compatible -and -not $ForceVersion) {
                    throw ('插件与当前 DSH 版本不兼容（要求 ' + $info.EngineRange + '）。勾选"允许版本不兼容"可强制安装。')
                }
                $res = Invoke-DshPluginCli -Cli $cli -ProfileName $profileName -Arguments @('add', ('file:' + ($copy -replace '\\', '/')))
                if ($res.ExitCode -ne 0 -and $ForceVersion) {
                    $m = [regex]::Match($res.Output, 'allow-version\s+(\S+@\S+)\s+--dsh-version\s+(\S+)\s+--accept-risk')
                    if ($m.Success) {
                        Write-InstallLog '版本检查被拒绝，尝试写入版本豁免后重试…' 'warn'
                        $pkgVersion = $m.Groups[1].Value
                        $rt = $m.Groups[2].Value
                        [void](Invoke-DshPluginCli -Cli $cli -ProfileName $profileName -Arguments @('allow-version', $pkgVersion, '--dsh-version', $rt, '--accept-risk'))
                        $res = Invoke-DshPluginCli -Cli $cli -ProfileName $profileName -Arguments @('add', ('file:' + ($copy -replace '\\', '/')))
                    }
                }
                if ($res.ExitCode -ne 0) {
                    if ($res.Output -match 'pnpm was not found') {
                        throw '官方命令行报告 pnpm 缺失。请改用桌面版安装器（自带 pnpm），或勾选"备用安装模式"。'
                    }
                    throw ('官方安装命令失败（退出码 ' + $res.ExitCode + '）。日志：' + $LogFile)
                }
                $installOk = $true
            } else {
                Install-PluginManual -Info $info -ProfileName $profileName -PluginCopyDir $copy
                $installOk = $true
            }

            # 版本不兼容但用户已同意：写"精确版本豁免"，否则 DSH 启动时会把这一行 disabled 掉
            if ($installOk -and -not $compatible -and $ForceVersion -and $runtime) {
                $pin = $info.Name + '@' + $info.Version
                $granted = $false
                if ($cli) {
                    try {
                        $r2 = Invoke-DshPluginCli -Cli $cli -ProfileName $profileName -Arguments @('allow-version', $pin, '--dsh-version', $runtime, '--accept-risk')
                        if ([int]$r2.ExitCode -eq 0) { $granted = $true; Write-InstallLog ('已用官方命令登记版本豁免：' + $pin + ' @ DSH ' + $runtime) 'warn' }
                    } catch { }
                }
                if (-not $granted) {
                    try { [void](Add-ProfileVersionExemption -ProfileName $profileName -PackageName $info.Name -PackageVersion $info.Version -RuntimeVersion $runtime) }
                    catch { Write-InstallLog ('写入版本豁免失败：' + $_.Exception.Message) 'warn' }
                }
            }

            if ($installOk -and $EnableConfig) {
                [void](Add-ProfilePatchEntry -Info $info -ProfileName $profileName)
            }

            $state = Get-PluginInstallState -PluginName $info.Name -ProfileName $profileName
            Write-InstallLog ('检查结果：依赖=' + $state.Declared + '，bundles=' + $state.InBundles + '，已就位=' + $state.InNodeModules) 'ok'
            if (-not $state.InNodeModules) {
                Write-InstallLog '注意：node_modules 里还没有插件文件，DSH 启动时可能加载不到。' 'warn'
            }
            $report.Profiles += [pscustomobject]@{
                Profile      = $profileName
                Declared     = $state.Declared
                InBundles    = $state.InBundles
                InNodeModules = $state.InNodeModules
                Version      = $state.InstalledVersion
            }
        }

        $report.Ok = $true
        $report.Message = ('已安装 ' + $info.Name + ' v' + $info.Version + ' 到：' + ($Profiles -join '、'))
        Write-InstallLog '===== 安装完成 =====' 'ok'
        Write-InstallLog '下一步：启动 DSH，在左侧「插件」页面确认插件已开启。' 'ok'
    } catch {
        $report.Ok = $false
        $report.Error = $_.Exception.Message
        Write-InstallLog ('安装失败：' + $_.Exception.Message) 'error'
    }
    return [pscustomobject]$report
}

# ------------------------------------------------------------------ 工作流：卸载

function Invoke-UninstallWorkflow {
    param(
        [string]$PluginName,
        [string[]]$Profiles = @(),
        [bool]$DeleteCopy = $false,
        [string]$LogFile = $null
    )
    if ($LogFile) { Set-InstallerLogFile -Path $LogFile }
    $report = [ordered]@{ Ok = $false; Title = $PluginName; Message = ''; Error = ''; LogFile = $LogFile }
    try {
        Write-InstallLog '===== 开始卸载 =====' 'step'
        Write-InstallLog ('插件：' + $PluginName)
        $cli = Find-DshCli
        foreach ($profileName in $Profiles) {
            Write-InstallLog ('----- 目标：' + $profileName + ' -----', 'step')
            $state = Get-PluginInstallState -PluginName $PluginName -ProfileName $profileName
            if (-not $state.Initialized) { Write-InstallLog '配置未初始化，跳过' 'warn'; continue }
            if ($state.Declared -or $state.InNodeModules) {
                $done = $false
                if ($cli -and -not ($cli.Kind -eq 'npm' -and -not (Get-Command 'pnpm' -ErrorAction SilentlyContinue))) {
                    $res = Invoke-DshPluginCli -Cli $cli -ProfileName $profileName -Arguments @('remove', $PluginName)
                    if ($res.ExitCode -eq 0) { $done = $true }
                }
                if (-not $done) { [void](Uninstall-PluginManual -PluginName $PluginName -ProfileName $profileName) }
            } else {
                Write-InstallLog '该配置里没有这个插件，跳过' 'warn'
            }
            Remove-ProfilePatchEntry -PluginName $PluginName -ProfileName $profileName
        }
        if ($DeleteCopy) {
            $root = Join-Path (Get-DshHomePath) 'local-plugins'
            if (Test-Path -LiteralPath $root) {
                Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -like ($PluginName -replace '[/\\]', '__') + '-*' } | ForEach-Object {
                    $copyDir = $_
                    # 只要还有别的配置指向这份副本，就绝对不能删（否则那个配置会坏掉）
                    $stillUsed = @()
                    foreach ($p in (Get-DshProfiles)) {
                        if (-not $p.Initialized) { continue }
                        try {
                            $m = Read-ProfileManifest -ProfileDir $p.Dir
                            if ($m.dependencies) {
                                foreach ($prop in $m.dependencies.PSObject.Properties) {
                                    if ([string]$prop.Value -match [regex]::Escape($copyDir.Name)) { $stillUsed += $p.Name }
                                }
                            }
                        } catch { }
                    }
                    if (@($stillUsed).Count -gt 0) {
                        Write-InstallLog ('本地仓库副本仍被其他配置使用，保留：' + $copyDir.FullName + '（' + (($stillUsed | Select-Object -Unique) -join '、') + '）') 'warn'
                    } else {
                        Remove-Item -LiteralPath $copyDir.FullName -Recurse -Force
                        Write-InstallLog ('已删除本地仓库副本：' + $copyDir.FullName) 'ok'
                    }
                }
            }
        }
        $report.Ok = $true
        $report.Message = ('已卸载 ' + $PluginName + '（' + ($Profiles -join '、') + '）')
        Write-InstallLog '===== 卸载完成 =====' 'ok'
    } catch {
        $report.Ok = $false
        $report.Error = $_.Exception.Message
        Write-InstallLog ('卸载失败：' + $_.Exception.Message) 'error'
    }
    return [pscustomobject]$report
}

# ------------------------------------------------------------------ 工作流：状态

function Invoke-StatusWorkflow {
    param([string]$PluginPath, [string]$LogFile = $null)
    if ($LogFile) { Set-InstallerLogFile -Path $LogFile }
    $out = [ordered]@{ Ok = $true; Plugin = ''; Rows = (New-Object System.Collections.ArrayList); Error = '' }
    try {
        $cli = Find-DshCli
        $runtime = Get-DshRuntimeVersion -Cli $cli
        Write-InstallLog '===== 环境与安装状态 =====' 'step'
        Write-InstallLog ('DSH 主目录：' + (Get-DshHomePath))
        if ($cli) { Write-InstallLog ('命令行：' + $cli.Path + '（' + $cli.Kind + '）') } else { Write-InstallLog '命令行：未找到（将只能使用备用模式）' 'warn' }
        Write-InstallLog ('DSH 版本：' + $(if ($runtime) { $runtime } else { '未知' }))
        if (Test-DshDesktopRunning) { Write-InstallLog '检测到 DeepSeek Harness 正在运行 —— 安装前请完全退出（含托盘）。' 'warn' }

        $profiles = Get-DshProfiles
        if (@($profiles).Count -eq 0) { Write-InstallLog '还没有任何 profile。' 'warn' }
        foreach ($p in $profiles) {
            Write-InstallLog ('配置 ' + $p.Name + '：' + $p.Dir + '（依赖 ' + $p.DependencyCount + ' 个）')
        }

        if ($PluginPath) {
            $source = Resolve-PluginSource -Path $PluginPath
            $info = Read-PluginInfo -Dir $source
            $out.Plugin = $info.Name
            Write-InstallLog ('插件：' + $info.Name + ' v' + $info.Version + '，要求 DSH ' + $(if ($info.EngineRange) { $info.EngineRange } else { '不限' }))
            foreach ($p in $profiles) {
                $state = Get-PluginInstallState -PluginName $info.Name -ProfileName $p.Name
                [void]$out.Rows.Add([pscustomobject]@{ Profile = $p.Name; Declared = $state.Declared; InBundles = $state.InBundles; InNodeModules = $state.InNodeModules; Version = $state.InstalledVersion })
                Write-InstallLog ('  ' + $p.Name + '：依赖=' + $state.Declared + '，bundles=' + $state.InBundles + '，已就位=' + $state.InNodeModules + '，已装版本=' + $state.InstalledVersion)
                if ($info.EngineRange -and $runtime) {
                    $cc = Test-SemVerRange -Version $runtime -Range $info.EngineRange
                    if (-not $cc.Unknown -and -not $cc.InRange) {
                        $ex = Test-ProfileVersionExemption -ProfileName $p.Name -PackageName $info.Name -PackageVersion $info.Version -RuntimeVersion $runtime
                        Write-InstallLog ('    这个插件要求 DSH ' + $info.EngineRange + '，当前 ' + $runtime + '；版本豁免=' + $(if ($ex) { '已开启（能被加载）' } else { '未开启（会被 DSH 自动停用）' })) 'warn'
                    }
                }
            }
        }
    } catch {
        $out.Ok = $false
        $out.Error = $_.Exception.Message
        Write-InstallLog ('检查失败：' + $_.Exception.Message) 'error'
    }
    return [pscustomobject]$out
}
