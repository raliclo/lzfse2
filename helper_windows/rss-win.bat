@echo off
chcp 65001 >nul
setlocal
set "RSS_DATASET=%~1"
set "RSS_N=%~2"
set "RSS_WRITE=%~3"
set "RSS_DIR=%~dp0"
if "%RSS_DATASET%"=="" (
    echo Usage: rss-win.bat ^<dataset^> [n] [write]
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '%~f0' -Encoding UTF8 | Select-Object -Skip 14 | Out-String | Invoke-Expression"
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%

# ===== PowerShell starts here =====
$dir = $env:RSS_DIR
Set-Location $dir
$dataset = $env:RSS_DATASET
$n = $env:RSS_N
$writeMode = ($env:RSS_WRITE -ieq 'write')
$outputMode = if ($writeMode) { 'file' } else { 'nul' }
$cli = Join-Path $dir 'lzfse.exe'
$sysTar = Join-Path $env:SystemRoot 'System32\tar.exe'
$csvDir = Join-Path $dir 'bench_results_csv'
$benchLogDir = Join-Path $dir 'bench_logs'
$tmpRoot = Join-Path $benchLogDir ('rss_tmp_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $csvDir | Out-Null
New-Item -ItemType Directory -Force -Path $benchLogDir | Out-Null
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

$datasetLeaf = Split-Path -Leaf $dataset
if (-not $datasetLeaf) { $datasetLeaf = 'dataset' }
$safeDataset = $datasetLeaf -replace '[^A-Za-z0-9_.-]', '_'
$safeN = if ($n) { $n } else { 'default' }
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$rssLog = Join-Path $benchLogDir ($safeDataset + '-rss-' + $outputMode + '-n' + $safeN + '-' + $timestamp + '.log')
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
Write-Log ('[rss] output: write to ' + $outputMode)

if (-not (Test-Path -LiteralPath $cli)) { Write-Log 'lzfse.exe not found; run compile.bat first'; exit 1 }
if (-not (Test-Path -LiteralPath $dataset)) { Write-Log 'dataset not found'; exit 1 }

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class RssJob {
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr CreateJobObject(IntPtr a,string n);
    [DllImport("kernel32.dll")] public static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
"@

function New-ProcessStartInfo([string]$fileName, [string]$arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $fileName
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    return $psi
}

function Poll-Peak($proc, $job) {
    [RssJob]::AssignProcessToJobObject($job, $proc.Handle) | Out-Null
    $peak = 0
    while (-not $proc.HasExited) {
        try {
            $proc.Refresh()
            if ($proc.PeakWorkingSet64 -gt $peak) { $peak = $proc.PeakWorkingSet64 }
        } catch {}
        Start-Sleep -Milliseconds 4
    }
    return $peak
}

function Measure-StandaloneRSS([string]$toolPath, [string]$arguments) {
    $job = [RssJob]::CreateJobObject([IntPtr]::Zero, $null)
    $psi = New-ProcessStartInfo $toolPath $arguments
    $p = [System.Diagnostics.Process]::Start($psi)
    $drain = $p.StandardOutput.BaseStream.CopyToAsync([System.IO.Stream]::Null)
    $errTask = $p.StandardError.ReadToEndAsync()
    $peak = Poll-Peak $p $job
    $drain.Wait()
    $err = $errTask.Result
    [RssJob]::CloseHandle($job) | Out-Null
    [pscustomobject]@{ exit = $p.ExitCode; rss_mb = [math]::Round($peak / 1MB, 1); err = $err }
}

function Measure-TarToProcessRSS([string]$toolPath, [string]$toolArgs, [string]$parent, [string]$name, [string]$stdoutFile = '') {
    $job = [RssJob]::CreateJobObject([IntPtr]::Zero, $null)
    $tpsi = New-ProcessStartInfo $sysTar "-cf - -C `"$parent`" `"$name`""
    $tp = [System.Diagnostics.Process]::Start($tpsi)

    $psi = New-ProcessStartInfo $toolPath $toolArgs
    $psi.RedirectStandardInput = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    [RssJob]::AssignProcessToJobObject($job, $p.Handle) | Out-Null

    $outStream = if ($stdoutFile) {
        [System.IO.File]::Open($stdoutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    } else {
        [System.IO.Stream]::Null
    }
    $feed = $tp.StandardOutput.BaseStream.CopyToAsync($p.StandardInput.BaseStream)
    $drain = $p.StandardOutput.BaseStream.CopyToAsync($outStream)
    $errTask = $p.StandardError.ReadToEndAsync()

    $peak = 0
    $closed = $false
    while (-not $p.HasExited) {
        if ($feed.IsCompleted -and -not $closed) {
            try { $p.StandardInput.Close() } catch {}
            $closed = $true
        }
        try {
            $p.Refresh()
            if ($p.PeakWorkingSet64 -gt $peak) { $peak = $p.PeakWorkingSet64 }
        } catch {}
        Start-Sleep -Milliseconds 4
    }
    if (-not $closed) { try { $p.StandardInput.Close() } catch {} }
    try { $feed.Wait() } catch {}
    $drain.Wait()
    $outStream.Dispose()
    try { $tp.WaitForExit() } catch {}
    $err = $errTask.Result
    [RssJob]::CloseHandle($job) | Out-Null
    [pscustomobject]@{ exit = $p.ExitCode; rss_mb = [math]::Round($peak / 1MB, 1); err = $err }
}

function Measure-ProcessToTarRSS([string]$toolPath, [string]$toolArgs, [string]$outDir = '') {
    $job = [RssJob]::CreateJobObject([IntPtr]::Zero, $null)
    $psi = New-ProcessStartInfo $toolPath $toolArgs
    $p = [System.Diagnostics.Process]::Start($psi)
    [RssJob]::AssignProcessToJobObject($job, $p.Handle) | Out-Null

    if ($outDir) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        $tpsi = New-Object System.Diagnostics.ProcessStartInfo
        $tpsi.FileName = $sysTar
        $tpsi.Arguments = "-xf - -C `"$outDir`""
        $tpsi.UseShellExecute = $false
        $tpsi.CreateNoWindow = $true
        $tpsi.RedirectStandardInput = $true
        $tpsi.RedirectStandardError = $true
        $tp = [System.Diagnostics.Process]::Start($tpsi)
        $drain = $p.StandardOutput.BaseStream.CopyToAsync($tp.StandardInput.BaseStream)
        $tarErrTask = $tp.StandardError.ReadToEndAsync()
    } else {
        $drain = $p.StandardOutput.BaseStream.CopyToAsync([System.IO.Stream]::Null)
        $tp = $null
        $tarErrTask = $null
    }
    $errTask = $p.StandardError.ReadToEndAsync()

    $peak = 0
    while (-not $p.HasExited) {
        try {
            $p.Refresh()
            if ($p.PeakWorkingSet64 -gt $peak) { $peak = $p.PeakWorkingSet64 }
        } catch {}
        Start-Sleep -Milliseconds 4
    }
    $drain.Wait()
    if ($tp) {
        try { $tp.StandardInput.Close() } catch {}
        try { $tp.WaitForExit() } catch {}
        $null = $tarErrTask.Result
    }
    $err = $errTask.Result
    [RssJob]::CloseHandle($job) | Out-Null
    [pscustomobject]@{ exit = $p.ExitCode; rss_mb = [math]::Round($peak / 1MB, 1); err = $err }
}

$formats = @(
    @{ name = 'Other3';  enc = '-algo other3';       dec = '-algo other3';        ext = 'lzfse.other3'  },
    @{ name = 'BVX3';    enc = '-algo bvx3';         dec = '-algo bvx3';          ext = 'lzfse.bvx3'    },
    @{ name = 'Lazy2';   enc = '-algo bvx3 -lazy2';  dec = '-algo bvx3 -lazy2';   ext = 'lzfse.lazy2'   },
    @{ name = 'Optimal'; enc = '-algo bvx3 -optimal';dec = '-algo bvx3 -optimal'; ext = 'lzfse.optimal' }
)
$nopt = if ($n) { "-n $n" } else { "" }
$lz4Exe = (Get-Command lz4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
$zstdExe = (Get-Command zstd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
$dsItem = Get-Item -LiteralPath $dataset
$parent = $dsItem.Parent.FullName
$name = $dsItem.Name

function Archive-Path([string]$extension) {
    Join-Path $parent ($name + "." + $extension)
}

$rows = @('dataset,format,output_mode,encode_rss_mb,decode_rss_mb')
foreach ($f in $formats) {
    Write-Log ("[rss] " + $f.name + " (" + $outputMode + ") ...")
    if ($writeMode) {
        $out = Join-Path $tmpRoot ($f.name + '.' + $f.ext)
        $e = Measure-TarToProcessRSS $cli ("-encode " + $f.enc + " -si " + $nopt + " -o `"$out`"") $parent $name
    } else {
        $e = Measure-TarToProcessRSS $cli ("-encode " + $f.enc + " -si -so " + $nopt) $parent $name
    }
    $encRss = $e.rss_mb
    if ($e.exit -ne 0) { Write-Log ("  [warn] encode exit " + $e.exit + ": " + (($e.err -split "`n")[0])) }

    $archive = Archive-Path $f.ext
    $decRss = ''
    if (Test-Path -LiteralPath $archive) {
        $outDir = if ($writeMode) { Join-Path $tmpRoot ('decode_' + $f.name) } else { '' }
        $d = Measure-ProcessToTarRSS $cli ("-decode -i `"$archive`" -so " + $f.dec + " " + $nopt) $outDir
        $decRss = $d.rss_mb
        if ($d.exit -ne 0) { Write-Log ("  [warn] decode exit " + $d.exit + ": " + (($d.err -split "`n")[0])) }
    } else {
        Write-Log ("  (skip decode: " + $archive + " not found; run encode-win.bat write first)")
    }
    Write-Log ("  encode RSS = " + $encRss + " MB   decode RSS = " + $decRss + " MB")
    $rows += ($name + "," + $f.name + "," + $outputMode + "," + $encRss + "," + $decRss)
}

Write-Log ("[rss] LZ4 (" + $outputMode + ") ...")
if ($lz4Exe) {
    if ($writeMode) {
        $out = Join-Path $tmpRoot 'out.tar.lz4'
        $e = Measure-TarToProcessRSS $lz4Exe "-9 -q -f - `"$out`"" $parent $name
    } else {
        $e = Measure-TarToProcessRSS $lz4Exe "-9 -q -c -" $parent $name
    }
    $encRss = $e.rss_mb
    if ($e.exit -ne 0) { Write-Log ("  [warn] lz4 encode exit " + $e.exit + ": " + (($e.err -split "`n")[0])) }
    $archive = Archive-Path 'tar.lz4'
    $decRss = ''
    if (Test-Path -LiteralPath $archive) {
        $outDir = if ($writeMode) { Join-Path $tmpRoot 'decode_lz4' } else { '' }
        $d = Measure-ProcessToTarRSS $lz4Exe "-d -q -c `"$archive`"" $outDir
        $decRss = $d.rss_mb
        if ($d.exit -ne 0) { Write-Log ("  [warn] lz4 decode exit " + $d.exit + ": " + (($d.err -split "`n")[0])) }
    } else { Write-Log ("  (skip decode: $archive not found)") }
    Write-Log ("  encode RSS = $encRss MB   decode RSS = $decRss MB")
    $rows += ($name + ",LZ4," + $outputMode + "," + $encRss + "," + $decRss)
} else {
    Write-Log '  (lz4 not found in PATH; skipping)'
    $rows += ($name + ",LZ4," + $outputMode + ",n/a,n/a")
}

Write-Log ("[rss] ZSTD (" + $outputMode + ") ...")
if ($zstdExe) {
    if ($writeMode) {
        $out = Join-Path $tmpRoot 'out.tar.zst'
        $e = Measure-TarToProcessRSS $zstdExe "-9 -q -f - -o `"$out`"" $parent $name
    } else {
        $e = Measure-TarToProcessRSS $zstdExe "-9 -q -c -" $parent $name
    }
    $encRss = $e.rss_mb
    if ($e.exit -ne 0) { Write-Log ("  [warn] zstd encode exit " + $e.exit + ": " + (($e.err -split "`n")[0])) }
    $archive = Archive-Path 'tar.zst'
    $decRss = ''
    if (Test-Path -LiteralPath $archive) {
        $outDir = if ($writeMode) { Join-Path $tmpRoot 'decode_zstd' } else { '' }
        $d = Measure-ProcessToTarRSS $zstdExe "-d -q -c `"$archive`"" $outDir
        $decRss = $d.rss_mb
        if ($d.exit -ne 0) { Write-Log ("  [warn] zstd decode exit " + $d.exit + ": " + (($d.err -split "`n")[0])) }
    } else { Write-Log ("  (skip decode: $archive not found)") }
    Write-Log ("  encode RSS = $encRss MB   decode RSS = $decRss MB")
    $rows += ($name + ",ZSTD," + $outputMode + "," + $encRss + "," + $decRss)
} else {
    Write-Log '  (zstd not found in PATH; skipping)'
    $rows += ($name + ",ZSTD," + $outputMode + ",n/a,n/a")
}

Write-Log ("[rss] Tgz (" + $outputMode + ") ...")
if ($writeMode) {
    $out = Join-Path $tmpRoot 'out.tgz'
    $e = Measure-StandaloneRSS $sysTar "-czf `"$out`" -C `"$parent`" `"$name`""
} else {
    $e = Measure-StandaloneRSS $sysTar "-czf - -C `"$parent`" `"$name`""
}
$encRss = $e.rss_mb
if ($e.exit -ne 0) { Write-Log ("  [warn] tgz encode exit " + $e.exit + ": " + (($e.err -split "`n")[0])) }
$archive = Archive-Path 'tgz'
$decRss = ''
if (Test-Path -LiteralPath $archive) {
    if ($writeMode) {
        $outDir = Join-Path $tmpRoot 'decode_tgz'
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        $d = Measure-StandaloneRSS $sysTar "-xzf `"$archive`" -C `"$outDir`""
    } else {
        $d = Measure-StandaloneRSS $sysTar "--to-stdout -xzf `"$archive`""
    }
    $decRss = $d.rss_mb
    if ($d.exit -ne 0) { Write-Log ("  [warn] tgz decode exit " + $d.exit + ": " + (($d.err -split "`n")[0])) }
} else {
    Write-Log ("  (skip decode: $archive not found)")
}
Write-Log ("  encode RSS = $encRss MB   decode RSS = $decRss MB")
$rows += ($name + ",Tgz," + $outputMode + "," + $encRss + "," + $decRss)

$mergedRows = @('dataset,format,output_mode,encode_rss_mb,decode_rss_mb')
if (Test-Path -LiteralPath $rssSummary) {
    try {
        Import-Csv -LiteralPath $rssSummary | Where-Object {
            $_.dataset -and -not ($_.dataset -eq $name -and $_.output_mode -eq $outputMode)
        } | ForEach-Object {
            $mode = if ($_.output_mode) { $_.output_mode } else { 'nul' }
            $mergedRows += ($_.dataset + ',' + $_.format + ',' + $mode + ',' + $_.encode_rss_mb + ',' + $_.decode_rss_mb)
        }
    } catch {}
}
$mergedRows += $rows | Select-Object -Skip 1
$mergedRows | Out-File -LiteralPath $rssSummary -Encoding UTF8

Write-Log ''
Write-Log ("[OK] " + $rssSummary + " written (peak RSS = Peak Working Set, n=$n, output=$outputMode):")
$mergedRows | ForEach-Object { Write-Log ("  " + $_) }
Write-Log ('[rss] finish: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

try { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
