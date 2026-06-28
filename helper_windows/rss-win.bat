@echo off
chcp 65001 >nul
setlocal
set "RSS_DATASET=%~1"
set "RSS_N=%~2"
set "RSS_DIR=%~dp0"
if "%RSS_DATASET%"=="" ( echo Usage: rss-win.bat ^<dataset^> [n]   e.g.  rss-win.bat ..\claw-code 40 & exit /b 1 )
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '%~f0' -Encoding UTF8 | Select-Object -Skip 10 | Out-String | Invoke-Expression"
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
# ===== PowerShell（前 10 行為 batch，PowerShell 由此開始）=====
# rss-win.bat — 量 lzfse.exe 各格式 encode/decode 峰值 RSS（= Peak Working Set），輸出 rss_summary.csv
# Measure peak RSS (Peak Working Set) of lzfse.exe per format; writes rss_summary.csv.
# 原理：Job Object 指派程序 + 執行中輪詢 PeakWorkingSet64 + 一律 -so 串流並非同步排空（不落地大檔）。
# Method: assign to a Job Object, poll PeakWorkingSet64 during the run, always stream via -so + drain async.
$dir = $env:RSS_DIR
Set-Location $dir
$dataset = $env:RSS_DATASET
$n = $env:RSS_N
$cli = Join-Path $dir 'lzfse.exe'
$sysTar = Join-Path $env:SystemRoot 'System32\tar.exe'   # 明確用 Windows bsdtar（處理 C:\ 路徑、-f - 無冒號問題）
$csvDir = Join-Path $dir 'bench_results_csv'
$benchLogDir = Join-Path $dir 'bench_logs'
New-Item -ItemType Directory -Force -Path $csvDir | Out-Null
New-Item -ItemType Directory -Force -Path $benchLogDir | Out-Null
$datasetLeaf = Split-Path -Leaf $dataset
if (-not $datasetLeaf) { $datasetLeaf = 'dataset' }
$safeDataset = $datasetLeaf -replace '[^A-Za-z0-9_.-]', '_'
$safeN = if ($n) { $n } else { 'default' }
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$rssLog = Join-Path $benchLogDir ($safeDataset + '-rss-n' + $safeN + '-' + $timestamp + '.log')
$rssSummary = Join-Path $csvDir 'rss_summary.csv'
function Write-Log([string]$message = '') {
    Microsoft.PowerShell.Utility\Write-Host $message
    $message | Out-File -LiteralPath $rssLog -Append -Encoding UTF8
}
Write-Log ('[rss] log: ' + $rssLog)
Write-Log ('[rss] start: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Log ('[rss] cwd: ' + (Get-Location).Path)
Write-Log ('[rss] dataset: ' + $dataset)
Write-Log ('[rss] n: ' + $n)
if (-not (Test-Path $cli)) { Write-Log "找不到 lzfse.exe（請先執行 compile.bat）/ lzfse.exe not found"; exit 1 }
if (-not (Test-Path $dataset)) { Write-Log "找不到 dataset：$dataset / dataset not found"; exit 1 }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class RssJob {
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr CreateJobObject(IntPtr a,string n);
    [DllImport("kernel32.dll")] public static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
"@

# 輪詢 lzfse 程序的峰值 working set（MB），直到結束 / poll lzfse peak working set (MB) until exit
function Poll-Peak($proc, $job) {
    [RssJob]::AssignProcessToJobObject($job, $proc.Handle) | Out-Null
    $peak = 0
    while (-not $proc.HasExited) {
        try { $proc.Refresh(); $w = $proc.PeakWorkingSet64; if ($w -gt $peak) { $peak = $w } } catch {}
        Start-Sleep -Milliseconds 4
    }
    return $peak
}

# DECODE RSS：lzfse -decode -i <archive> -so（輸出非同步排空）
function Measure-DecodeRSS([string]$arguments) {
    $job = [RssJob]::CreateJobObject([IntPtr]::Zero, $null)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cli; $psi.Arguments = $arguments
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $drain = $p.StandardOutput.BaseStream.CopyToAsync([System.IO.Stream]::Null)
    $errTask = $p.StandardError.ReadToEndAsync()
    $peak = Poll-Peak $p $job
    $drain.Wait(); $err = $errTask.Result; [RssJob]::CloseHandle($job) | Out-Null
    [pscustomobject]@{ exit = $p.ExitCode; rss_mb = [math]::Round($peak/1MB,1); err = $err }
}

# ENCODE RSS：tar -cf - -C <parent> <name> | lzfse -encode <algo> -si -so（串流，不落地 tar）
function Measure-EncodeRSS([string]$algoArgs, $parent, $name, $nopt) {
    $job = [RssJob]::CreateJobObject([IntPtr]::Zero, $null)
    $tpsi = New-Object System.Diagnostics.ProcessStartInfo
    $tpsi.FileName = $sysTar; $tpsi.Arguments = "-cf - -C `"$parent`" `"$name`""
    $tpsi.UseShellExecute = $false; $tpsi.CreateNoWindow = $true; $tpsi.RedirectStandardOutput = $true
    $tp = [System.Diagnostics.Process]::Start($tpsi)
    $lpsi = New-Object System.Diagnostics.ProcessStartInfo
    $lpsi.FileName = $cli; $lpsi.Arguments = "-encode $algoArgs -si -so $nopt"
    $lpsi.UseShellExecute = $false; $lpsi.CreateNoWindow = $true
    $lpsi.RedirectStandardInput = $true; $lpsi.RedirectStandardOutput = $true; $lpsi.RedirectStandardError = $true
    $lp = [System.Diagnostics.Process]::Start($lpsi)
    [RssJob]::AssignProcessToJobObject($job, $lp.Handle) | Out-Null
    $feed  = $tp.StandardOutput.BaseStream.CopyToAsync($lp.StandardInput.BaseStream)
    $drain = $lp.StandardOutput.BaseStream.CopyToAsync([System.IO.Stream]::Null)
    $errTask = $lp.StandardError.ReadToEndAsync()
    $peak = 0; $closed = $false
    while (-not $lp.HasExited) {
        if ($feed.IsCompleted -and -not $closed) { try { $lp.StandardInput.Close() } catch {}; $closed = $true }
        try { $lp.Refresh(); $w = $lp.PeakWorkingSet64; if ($w -gt $peak) { $peak = $w } } catch {}
        Start-Sleep -Milliseconds 4
    }
    if (-not $closed) { try { $lp.StandardInput.Close() } catch {} }
    $drain.Wait(); try { $feed.Wait() } catch {}; try { $tp.WaitForExit() } catch {}
    $err = $errTask.Result; [RssJob]::CloseHandle($job) | Out-Null
    [pscustomobject]@{ exit = $lp.ExitCode; rss_mb = [math]::Round($peak/1MB,1); err = $err }
}

# 外部壓縮工具 encode RSS：tar -cf - | $tool $args（stdout 排空），量 $tool 的 RSS
# External tool encode RSS: pipe tar → $tool, drain stdout, measure $tool's peak RSS
function Measure-PipeToolRSS([string]$toolPath, [string]$toolArgs, $parent, $name) {
    $job = [RssJob]::CreateJobObject([IntPtr]::Zero, $null)
    $tpsi = New-Object System.Diagnostics.ProcessStartInfo
    $tpsi.FileName = $sysTar; $tpsi.Arguments = "-cf - -C `"$parent`" `"$name`""
    $tpsi.UseShellExecute = $false; $tpsi.CreateNoWindow = $true; $tpsi.RedirectStandardOutput = $true
    $tp = [System.Diagnostics.Process]::Start($tpsi)
    $lpsi = New-Object System.Diagnostics.ProcessStartInfo
    $lpsi.FileName = $toolPath; $lpsi.Arguments = $toolArgs
    $lpsi.UseShellExecute = $false; $lpsi.CreateNoWindow = $true
    $lpsi.RedirectStandardInput = $true; $lpsi.RedirectStandardOutput = $true; $lpsi.RedirectStandardError = $true
    $lp = [System.Diagnostics.Process]::Start($lpsi)
    [RssJob]::AssignProcessToJobObject($job, $lp.Handle) | Out-Null
    $feed  = $tp.StandardOutput.BaseStream.CopyToAsync($lp.StandardInput.BaseStream)
    $drain = $lp.StandardOutput.BaseStream.CopyToAsync([System.IO.Stream]::Null)
    $errTask = $lp.StandardError.ReadToEndAsync()
    $peak = 0; $closed = $false
    while (-not $lp.HasExited) {
        if ($feed.IsCompleted -and -not $closed) { try { $lp.StandardInput.Close() } catch {}; $closed = $true }
        try { $lp.Refresh(); $w = $lp.PeakWorkingSet64; if ($w -gt $peak) { $peak = $w } } catch {}
        Start-Sleep -Milliseconds 4
    }
    if (-not $closed) { try { $lp.StandardInput.Close() } catch {} }
    $drain.Wait(); try { $feed.Wait() } catch {}; try { $tp.WaitForExit() } catch {}
    $err = $errTask.Result; [RssJob]::CloseHandle($job) | Out-Null
    [pscustomobject]@{ exit = $lp.ExitCode; rss_mb = [math]::Round($peak/1MB,1); err = $err }
}

# 單程序 RSS：$tool $args（stdout 排空），適用於 tgz encode/decode（tar 內建 gzip，無 pipe）
# Standalone RSS: $tool $args, drain stdout — for tgz where tar handles gzip internally
function Measure-StandaloneRSS([string]$toolPath, [string]$arguments) {
    $job = [RssJob]::CreateJobObject([IntPtr]::Zero, $null)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $toolPath; $psi.Arguments = $arguments
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $drain = $p.StandardOutput.BaseStream.CopyToAsync([System.IO.Stream]::Null)
    $errTask = $p.StandardError.ReadToEndAsync()
    $peak = Poll-Peak $p $job
    $drain.Wait(); $err = $errTask.Result; [RssJob]::CloseHandle($job) | Out-Null
    [pscustomobject]@{ exit = $p.ExitCode; rss_mb = [math]::Round($peak/1MB,1); err = $err }
}

$formats = @(
    @{ name = 'Other3';  enc = '-algo other3';       dec = '-algo other3'; ext = 'lzfse.other3' },
    @{ name = 'BVX3';    enc = '-algo bvx3';          dec = '-algo bvx3';   ext = 'lzfse.bvx3'   },
    @{ name = 'Lazy2';   enc = '-algo bvx3 -lazy2';   dec = '-algo bvx3';   ext = 'lzfse.lazy2'  },
    @{ name = 'Optimal'; enc = '-algo bvx3 -optimal'; dec = '-algo bvx3';   ext = 'lzfse.optimal' }
)
$nopt = if ($n) { "-n $n" } else { "" }
$lz4Exe  = (Get-Command lz4  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
$zstdExe = (Get-Command zstd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
$dsItem = Get-Item $dataset
$parent = $dsItem.Parent.FullName
$name   = $dsItem.Name

function Archive-Path([string]$extension) {
    Join-Path $parent ($name + "." + $extension)
}

$rows = @('format,encode_rss_mb,decode_rss_mb')
foreach ($f in $formats) {
    Write-Log ("[rss] " + $f.name + " ...")
    $e = Measure-EncodeRSS $f.enc $parent $name $nopt
    $encRss = $e.rss_mb
    if ($e.exit -ne 0) { Write-Log ("  [warn] encode exit " + $e.exit + ": " + (($e.err -split "`n")[0])) }
    $archive = Archive-Path $f.ext
    $decRss = ''
    if (Test-Path -LiteralPath $archive) {
        $d = Measure-DecodeRSS ("-decode -i `"$archive`" -so " + $f.dec + " " + $nopt)
        $decRss = $d.rss_mb
        if ($d.exit -ne 0) { Write-Log ("  [warn] decode exit " + $d.exit + ": " + (($d.err -split "`n")[0])) }
    } else {
        Write-Log ("  (skip decode: " + $archive + " 不存在 — 先跑 encode-win.bat)")
    }
    Write-Log ("  encode RSS = " + $encRss + " MB   decode RSS = " + $decRss + " MB")
    $rows += ($f.name + "," + $encRss + "," + $decRss)
}

# === LZ4 RSS ===
Write-Log "[rss] LZ4 ..."
if ($lz4Exe) {
    $e = Measure-PipeToolRSS $lz4Exe "-9 -q -c -" $parent $name
    $encRss = $e.rss_mb
    if ($e.exit -ne 0) { Write-Log ("  [warn] lz4 encode exit " + $e.exit + ": " + (($e.err -split "`n")[0])) }
    $archive = Archive-Path "tar.lz4"
    $decRss = ''
    if (Test-Path -LiteralPath $archive) {
        $d = Measure-StandaloneRSS $lz4Exe "-d -q -c `"$archive`""
        $decRss = $d.rss_mb
        if ($d.exit -ne 0) { Write-Log ("  [warn] lz4 decode exit " + $d.exit + ": " + (($d.err -split "`n")[0])) }
    } else { Write-Log ("  (skip decode: $archive 不存在 — 先跑 encode-win.bat)") }
    Write-Log ("  encode RSS = $encRss MB   decode RSS = $decRss MB")
    $rows += "LZ4,$encRss,$decRss"
} else { Write-Log "  (lz4 not found in PATH — skipping)"; $rows += "LZ4,n/a,n/a" }

# === ZSTD RSS ===
Write-Log "[rss] ZSTD ..."
if ($zstdExe) {
    $e = Measure-PipeToolRSS $zstdExe "-9 -q -c -" $parent $name
    $encRss = $e.rss_mb
    if ($e.exit -ne 0) { Write-Log ("  [warn] zstd encode exit " + $e.exit + ": " + (($e.err -split "`n")[0])) }
    $archive = Archive-Path "tar.zst"
    $decRss = ''
    if (Test-Path -LiteralPath $archive) {
        $d = Measure-StandaloneRSS $zstdExe "-d -q -c `"$archive`""
        $decRss = $d.rss_mb
        if ($d.exit -ne 0) { Write-Log ("  [warn] zstd decode exit " + $d.exit + ": " + (($d.err -split "`n")[0])) }
    } else { Write-Log ("  (skip decode: $archive 不存在 — 先跑 encode-win.bat)") }
    Write-Log ("  encode RSS = $encRss MB   decode RSS = $decRss MB")
    $rows += "ZSTD,$encRss,$decRss"
} else { Write-Log "  (zstd not found in PATH — skipping)"; $rows += "ZSTD,n/a,n/a" }

# === Tgz RSS（tar 內建 gzip，單程序量測）/ Tgz RSS (tar handles gzip internally) ===
Write-Log "[rss] Tgz ..."
$e = Measure-StandaloneRSS $sysTar "-czf - -C `"$parent`" `"$name`""
$encRss = $e.rss_mb
if ($e.exit -ne 0) { Write-Log ("  [warn] tgz encode exit " + $e.exit + ": " + (($e.err -split "`n")[0])) }
$archive = Archive-Path "tgz"
$decRss = ''
if (Test-Path -LiteralPath $archive) {
    $d = Measure-StandaloneRSS $sysTar "--to-stdout -xzf `"$archive`""
    $decRss = $d.rss_mb
    if ($d.exit -ne 0) { Write-Log ("  [warn] tgz decode exit " + $d.exit + ": " + (($d.err -split "`n")[0])) }
} else { Write-Log ("  (skip decode: $archive 不存在 — 先跑 encode-win.bat)") }
Write-Log ("  encode RSS = $encRss MB   decode RSS = $decRss MB")
$rows += "Tgz,$encRss,$decRss"

$rows | Out-File -LiteralPath $rssSummary -Encoding UTF8
Write-Log ""
Write-Log ("[OK] " + $rssSummary + " written (peak RSS = Peak Working Set, n=$n):")
$rows | ForEach-Object { Write-Log ("  " + $_) }
Write-Log ('[rss] finish: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
