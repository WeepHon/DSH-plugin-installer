$ErrorActionPreference = 'Stop'

# 把 DSH 插件安装器打成一个单文件 exe：
#   嵌入全部脚本/资源 → 用户双击即用，机器上只要有 Windows PowerShell 5.1（Win7+ 自带）。
# 用法：powershell -ExecutionPolicy Bypass -File build\build-exe.ps1

$build = $PSScriptRoot
$root = Split-Path $build -Parent
$stage = Join-Path $build 'stage'
$outDir = Join-Path $root 'dist'
$exeName = 'DSH插件安装器.exe'
$exePath = Join-Path $outDir $exeName

# 需要嵌入的东西：源文件 -> 暂存文件名（暂存名必须 ASCII，避免 csc 参数编码问题）
$map = [ordered]@{
    'DSH-Plugin-Installer.ps1'   = 'main.ps1'
    'cli-mode.ps1'               = 'cli.ps1'
    'core\dsh-plugin-core.ps1'   = 'core-plugin.ps1'
    'core\dsh-unlock-core.ps1'   = 'core-unlock.ps1'
    'core\dsh-unlock-dir.ps1'    = 'core-unlock-dir.ps1'
    'core\dsh-fallback-core.ps1' = 'core-fallback.ps1'
    'core\unlock-targets.json'   = 'targets.json'
    'tools\dsh-asar.cjs'         = 'asar.cjs'
    '使用说明.md'                = 'readme.md'
    '界面预览.png'               = 'preview.png'
    'plugins\把插件放这里.txt'   = 'plugins-note.txt'
    'build\app.ico'              = 'app.ico'
    '开始安装.bat'               = 'start.bat'
    '命令行模式.bat'             = 'cmd.bat'
}

if (Test-Path -LiteralPath $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$resArgs = @()
foreach ($src in $map.Keys) {
    $s = Join-Path $root $src
    if (-not (Test-Path -LiteralPath $s)) { throw "缺少文件：$s" }
    $dst = Join-Path $stage $map[$src]
    Copy-Item -LiteralPath $s -Destination $dst -Force
    $resArgs += ('/resource:' + $dst + ',' + $map[$src])
}

# 构建号：版本 + 时间戳（用来判断是否需要重新解压）
$version = '1.0.0'
$buildId = $version + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$srcCs = [System.IO.File]::ReadAllText((Join-Path $build 'Program.cs'), [System.Text.Encoding]::UTF8)
$genCs = $srcCs.Replace('__BUILD_ID__', $buildId)
$genPath = Join-Path $build 'Program.gen.cs'
[System.IO.File]::WriteAllText($genPath, $genCs, (New-Object System.Text.UTF8Encoding($true)))

$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw '找不到 .NET Framework 的 csc.exe' }

$ico = Join-Path $build 'app.ico'
$cscArgs = @(
    '/nologo',
    '/target:winexe',
    '/platform:anycpu',
    '/optimize+',
    '/warn:2',
    ('/out:' + $exePath),
    ('/win32icon:' + $ico),
    '/r:System.dll',
    '/r:System.Windows.Forms.dll',
    '/r:System.Drawing.dll',
    $genPath
) + $resArgs

Write-Host ('编译中… 构建号 ' + $buildId)
$out = & $csc @cscArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    $out | ForEach-Object { Write-Host $_ }
    throw ('编译失败，exit=' + $LASTEXITCODE)
}
$out | Where-Object { $_ -match 'warning|error' } | ForEach-Object { Write-Host $_ }

$size = [math]::Round((Get-Item $exePath).Length / 1KB, 1)
Write-Host ('完成：' + $exePath + '  ' + $size + ' KB')

Remove-Item $stage -Recurse -Force
Remove-Item $genPath -Force
