@echo off
setlocal
set "BATDIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '%~f0' -Encoding UTF8 | Select-Object -Skip 6 | Out-String | Invoke-Expression"
endlocal
exit /b
# ===== PowerShell（上方 6 行為 batch，PowerShell 由此開始）=====
# screenshot-win.bat — 擷取 LZFSE_UI_Win 視窗截圖，存到 screenshot/screenshot_win.png
# Capture the LZFSE_UI_Win window into screenshot/screenshot_win.png.
# 注意：WinUI 用 DirectComposition，需「視窗置前景且實際可見」才能正確擷取（CopyFromScreen）。
# Note: WinUI uses DirectComposition; the window must be foreground & actually visible on screen.
# 用法：先開啟 App 再執行本檔（擷取執行中的視窗），或直接執行（會自動啟動再擷取）。
# Usage: open the app then run this (captures the running window), or just run it (it launches then captures).
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinShot {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@

$batdir = $env:BATDIR
$proc = Get-Process LZFSE_UI_Win -ErrorAction SilentlyContinue | Select-Object -First 1
$launched = $false
if (-not $proc) {
    $candidates = @(
        (Join-Path $batdir ".win-build\.build\x86_64-unknown-windows-msvc\release\LZFSE_UI_Win.exe"),
        (Join-Path $batdir "LZFSE_UI_Win\LZFSE_UI_Win.exe")
    )
    $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) { Write-Host "找不到 LZFSE_UI_Win.exe；請先開啟 App 或先 build-win.zsh。/ LZFSE_UI_Win.exe not found."; exit 1 }
    $proc = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -PassThru
    $launched = $true
    Start-Sleep -Seconds 10
}

$proc.Refresh()
$h = $proc.MainWindowHandle
if ($h -eq 0) { Start-Sleep -Seconds 3; $proc.Refresh(); $h = $proc.MainWindowHandle }
if ($h -eq 0) { Write-Host "視窗尚未就緒 / window not ready"; if ($launched) { Stop-Process -Id $proc.Id -Force }; exit 1 }

# 置前景並還原，確保視窗在螢幕上可見再擷取
[WinShot]::ShowWindow($h, 9) | Out-Null   # SW_RESTORE
[WinShot]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 500

# Move the window near the top of the primary work area and make it tall enough
# for the full UI. CopyFromScreen can only capture pixels that are actually on
# screen, so keep the whole window inside the visible work area.
$work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$targetW = [Math]::Min(1040, [Math]::Max(820, $work.Width - 40))
$targetH = [Math]::Min(980, [Math]::Max(720, $work.Height - 16))
$targetX = $work.Left + [Math]::Max(20, [int](($work.Width - $targetW) / 2))
$targetY = $work.Top + 8
[WinShot]::SetWindowPos($h, [IntPtr]::Zero, $targetX, $targetY, $targetW, $targetH, 0x0040) | Out-Null # SWP_SHOWWINDOW
[WinShot]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 1500

$r = New-Object WinShot+RECT
[WinShot]::GetWindowRect($h, [ref]$r) | Out-Null
$w = $r.R - $r.L; $ht = $r.B - $r.T
if ($w -le 0 -or $ht -le 0) {
    Write-Host "Invalid window rectangle / 視窗範圍無效"
    if ($launched) { Stop-Process -Id $proc.Id -Force }
    exit 1
}

# Clamp the capture rectangle to the visible work area. If the window manager
# adds borders/shadows outside the work area, this avoids partial off-screen
# capture and still captures the full visible app content.
$capL = [Math]::Max($r.L, $work.Left)
$capT = [Math]::Max($r.T, $work.Top)
$capR = [Math]::Min($r.R, $work.Right)
$capB = [Math]::Min($r.B, $work.Bottom)
$capW = $capR - $capL
$capH = $capB - $capT
if ($capW -le 0 -or $capH -le 0) {
    Write-Host "Window is outside visible work area / 視窗不在可見工作區內"
    if ($launched) { Stop-Process -Id $proc.Id -Force }
    exit 1
}

$shotDir = Join-Path $batdir "screenshot"
New-Item -ItemType Directory -Force $shotDir | Out-Null
$out = Join-Path $shotDir "screenshot_win.png"
$bmp = New-Object System.Drawing.Bitmap($capW, $capH)
$g = [System.Drawing.Graphics]::FromImage($bmp)
# 視窗已置前景可見 → 擷取螢幕該區域（WinUI/DComp 內容最可靠的方式）
# Window is foreground & visible → grab that screen region (most reliable for WinUI/DComp content).
$g.CopyFromScreen($capL, $capT, 0, 0, (New-Object System.Drawing.Size($capW, $capH)))
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

Write-Host ("Saved / 已儲存: " + $out + "  (" + $capW + " x " + $capH + "), window=(" + $w + " x " + $ht + "), pos=(" + $r.L + "," + $r.T + ")")
if ($launched) { Stop-Process -Id $proc.Id -Force }
