# make-icon.ps1 -- PNG -> Windows .ico (multi-size, PNG-compressed frames).
#
# This is the ONE PowerShell file in the project, and it exists only because
# resizing an image needs a Windows imaging API (System.Drawing) and this machine
# has no image CLI -- ImageMagick is absent, and C:\Windows\System32\convert.exe
# is the FAT-to-NTFS converter, not a converter of images. Everything else in the
# build is zsh; keep it that way and keep this file to this one job.
#
# 本專案唯一的 PowerShell 檔案，存在的理由僅有一個：縮放影像需要 Windows 的影像 API
#（System.Drawing），而本機沒有任何影像 CLI——未安裝 ImageMagick，且
# C:\Windows\System32\convert.exe 是 FAT 轉 NTFS 的工具，並非影像轉換器。
# 建置的其餘部分一律為 zsh；請維持現狀，也請讓本檔只做這一件事。
#
# Called from build-win.zsh / 由 build-win.zsh 呼叫：
#   powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
#       -File make-icon.ps1 -SourcePng <in.png> -OutIco <out.ico>
param([string]$SourcePng, [string]$OutIco)
Add-Type -AssemblyName System.Drawing
$source = [System.Drawing.Image]::FromFile($SourcePng)
try {
    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $frames = New-Object System.Collections.Generic.List[byte[]]
    foreach ($size in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.DrawImage($source, 0, 0, $size, $size)
        } finally {
            $g.Dispose()
        }
        $ms = New-Object System.IO.MemoryStream
        try {
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $frames.Add($ms.ToArray())
        } finally {
            $ms.Dispose()
            $bmp.Dispose()
        }
    }

    $fs = [System.IO.File]::Create($OutIco)
    $bw = New-Object System.IO.BinaryWriter $fs
    try {
        $bw.Write([UInt16]0)
        $bw.Write([UInt16]1)
        $bw.Write([UInt16]$sizes.Count)
        $offset = 6 + (16 * $sizes.Count)
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $size = [int]$sizes[$i]
            $data = [byte[]]$frames[$i]
            $iconSize = [byte]$(if ($size -eq 256) { 0 } else { $size })
            $bw.Write($iconSize)
            $bw.Write($iconSize)
            $bw.Write([byte]0)
            $bw.Write([byte]0)
            $bw.Write([UInt16]1)
            $bw.Write([UInt16]32)
            $bw.Write([UInt32]$data.Length)
            $bw.Write([UInt32]$offset)
            $offset += $data.Length
        }
        foreach ($data in $frames) {
            $bw.Write([byte[]]$data)
        }
    } finally {
        $bw.Dispose()
        $fs.Dispose()
    }
} finally {
    $source.Dispose()
}
