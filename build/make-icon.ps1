$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$d = 'C:\Users\WeepHon\Documents\deepseek-harness\default-workspace\dsh-plugin-installer'
$build = Join-Path $d 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
$icoPath = Join-Path $build 'app.ico'

function New-IconBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.Clear([System.Drawing.Color]::Transparent)

    $pad = [math]::Round($size * 0.03)
    $rect = New-Object System.Drawing.Rectangle $pad, $pad, ($size - 2 * $pad), ($size - 2 * $pad)
    $radius = [math]::Round($size * 0.22)

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d2 = 2 * $radius
    $path.AddArc($rect.X, $rect.Y, $d2, $d2, 180, 90)
    $path.AddArc($rect.Right - $d2, $rect.Y, $d2, $d2, 270, 90)
    $path.AddArc($rect.Right - $d2, $rect.Bottom - $d2, $d2, $d2, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $d2, $d2, $d2, 90, 90)
    $path.CloseFigure()

    $c1 = [System.Drawing.Color]::FromArgb(255, 59, 130, 246)
    $c2 = [System.Drawing.Color]::FromArgb(255, 29, 78, 216)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, $c1, $c2, 55
    $g.FillPath($brush, $path)
    $brush.Dispose()

    # 白色向下箭头 + 托盘
    $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 255, 255))
    $w = $size * 0.11          # 箭杆宽
    $cx = $size / 2.0
    $top = $size * 0.20
    $stemBottom = $size * 0.52
    $g.FillRectangle($white, [single]($cx - $w / 2), [single]$top, [single]$w, [single]($stemBottom - $top))

    $head = New-Object System.Drawing.Drawing2D.GraphicsPath
    $hw = $size * 0.20
    $pt1 = [System.Drawing.PointF]::new([single]($cx - $hw), [single]$stemBottom)
    $pt2 = [System.Drawing.PointF]::new([single]($cx + $hw), [single]$stemBottom)
    $pt3 = [System.Drawing.PointF]::new([single]$cx, [single]($size * 0.72))
    $head.AddPolygon(@($pt1, $pt2, $pt3))
    $g.FillPath($white, $head)
    $head.Dispose()

    # 底座
    $baseH = $size * 0.075
    $baseY = $size * 0.78
    $baseW = $size * 0.52
    $baseRect = [System.Drawing.RectangleF]::new([single]($cx - $baseW / 2), [single]$baseY, [single]$baseW, [single]$baseH)
    $g.FillRectangle($white, $baseRect)

    $white.Dispose()
    $path.Dispose()
    $g.Dispose()
    return $bmp
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$pngs = @()
foreach ($s in $sizes) {
    $bmp = New-IconBitmap $s
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs += , $ms.ToArray()
    $ms.Dispose()
    $bmp.Dispose()
}

$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $out
$bw.Write([uint16]0)
$bw.Write([uint16]1)
$bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
    $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]$pngs[$i].Length)
    $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($icoPath, $out.ToArray())
$bw.Dispose(); $out.Dispose()

'ico: ' + $icoPath + '  ' + (Get-Item $icoPath).Length + ' bytes'

# 同时导出 png 预览
$big = New-IconBitmap 256
$big.Save((Join-Path $build 'app-256.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$big.Dispose()
