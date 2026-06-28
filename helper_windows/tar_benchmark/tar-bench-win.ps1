# tar-bench-win.ps1
# 量測 Windows tar extraction 速度，確認是否為 decode file-mode 瓶頸
# Measures Windows tar extraction speed to confirm whether it is the decode file-mode bottleneck.
#
# 測試項目 / Tests:
#   1. tar -tzf  : gz 解壓 + 列出清單（無 file creation）→ 純 CPU + read I/O
#   2. tar -xzf  : gz 解壓 + 展開至磁碟 → 含 file creation 開銷
#   差異 = Windows bsdtar file 建立 + NTFS metadata 開銷
#   Difference = Windows bsdtar file-creation + NTFS metadata overhead
#
# Usage: cd helper_windows\tar_benchmark && powershell -ExecutionPolicy Bypass -File tar-bench-win.ps1
# Results: saved to tar-bench-results.txt in the same folder as this script (overwritten each run)

$ErrorActionPreference = "Stop"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$resultFile = Join-Path $PSScriptRoot "tar-bench-results.txt"
# Overwrite file at start of each run
if (Test-Path $resultFile) { Remove-Item $resultFile }

function Log($msg) {
    Write-Host $msg
    Add-Content -Path $resultFile -Value $msg -Encoding UTF8
}

$datasets = @(
    [pscustomobject]@{ Name = "claw-code"; Tgz = Join-Path $PSScriptRoot "..\..\claw-code.tgz"; UncompMB = 1416.8 }
    [pscustomobject]@{ Name = "llama.cpp"; Tgz = Join-Path $PSScriptRoot "..\..\llama.cpp.tgz"; UncompMB = 1322.4 }
)

$tempBase = Join-Path $PSScriptRoot "tar-bench-temp"
if (Test-Path $tempBase) { Remove-Item -Recurse -Force $tempBase }
New-Item -ItemType Directory -Path $tempBase | Out-Null

Log ""
Log "============================================================"
Log " Windows tar extraction benchmark  $timestamp"
Log " tar -tzf = gz decompress + list (no file write)"
Log " tar -xzf = gz decompress + extract to disk"
Log "============================================================"

foreach ($ds in $datasets) {
    $tgz = $ds.Tgz
    $mb  = $ds.UncompMB

    if (-not (Test-Path $tgz)) {
        Log "`n[SKIP] $($ds.Name): $tgz not found"
        continue
    }

    $tgzSizeMB = [math]::Round((Get-Item $tgz).Length / 1MB, 1)
    Log ""
    Log "--- $($ds.Name)  (tgz: $tgzSizeMB MB, uncompressed ref: $mb MB) ---"

    # warm OS cache
    Log "  [warm] pre-reading tgz into OS page cache..."
    cmd /c "tar -tzf `"$tgz`" > nul 2>&1" | Out-Null

    # Test 1: tar -tzf (list only — no file creation)
    $t = Measure-Command { cmd /c "tar -tzf `"$tgz`" > nul 2>&1" }
    $secs1 = [math]::Round($t.TotalSeconds, 2)
    $mbps1 = [math]::Round($mb / $t.TotalSeconds, 1)
    Log ("  tar -tzf (list, no write) : {0,6}s  ->  {1,7} MB/s" -f $secs1, $mbps1)

    # Test 2: tar -xzf (extract to temp dir)
    $outDir = Join-Path $tempBase $ds.Name
    New-Item -ItemType Directory -Path $outDir | Out-Null

    $t = Measure-Command { cmd /c "tar -xzf `"$tgz`" -C `"$outDir`" 2>&1" }
    $secs2 = [math]::Round($t.TotalSeconds, 2)
    $mbps2 = [math]::Round($mb / $t.TotalSeconds, 1)
    Log ("  tar -xzf (extract files)  : {0,6}s  ->  {1,7} MB/s" -f $secs2, $mbps2)

    $ratio = [math]::Round($mbps1 / $mbps2, 2)
    Log ("  list/extract speed ratio  : {0}x  (>1 = file creation is bottleneck)" -f $ratio)

    Remove-Item -Recurse -Force $outDir
}

Remove-Item -Recurse -Force $tempBase

Log ""
Log "============================================================"
Log " Done. Compare list vs extract MB/s:"
Log "   list >> extract  => bsdtar file creation + NTFS is bottleneck"
Log "   list ~= extract  => gz decompression is bottleneck"
Log "============================================================"
Log ""
Log "Results saved to: $resultFile"
