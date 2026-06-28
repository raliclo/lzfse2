@echo off
chcp 65001 > nul
setlocal
set "INFO_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -LiteralPath '%~f0' -Encoding UTF8 | Select-Object -Skip 7 | Out-String | Invoke-Expression"
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%

# Collect Windows CPU/GPU/memory/storage info.
# Outputs to console and writes a UTF-8 log under helper_windows/bench_logs.
$ErrorActionPreference = "Continue"
$dir = $env:INFO_DIR
Set-Location $dir

$logDir = Join-Path $dir "bench_logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logPath = Join-Path $logDir "system-info.txt"
if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force }

function Write-Log([string]$message = "") {
    Microsoft.PowerShell.Utility\Write-Host $message
    $message | Out-File -LiteralPath $logPath -Append -Encoding UTF8
}

function Format-Bytes([Nullable[double]]$bytes) {
    if ($null -eq $bytes -or $bytes -le 0) { return "" }
    if ($bytes -ge 1TB) { return ("{0:N2} TB" -f ($bytes / 1TB)) }
    if ($bytes -ge 1GB) { return ("{0:N2} GB" -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ("{0:N2} MB" -f ($bytes / 1MB)) }
    return ("{0:N0} bytes" -f $bytes)
}

function Try-Cim([string]$className) {
    try {
        return Get-CimInstance $className -ErrorAction Stop
    } catch {
        Write-Log ("[WARN] Cannot read " + $className + ": " + $_.Exception.Message)
        return @()
    }
}

Write-Log ("Windows hardware info / Windows 硬體資訊")
Write-Log ("Timestamp: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Write-Log ("Log: " + $logPath)
Write-Log ""

$computer = Try-Cim "Win32_ComputerSystem"
if ($computer) {
    Write-Log "== Computer =="
    foreach ($item in $computer) {
        Write-Log ("Manufacturer: " + $item.Manufacturer)
        Write-Log ("Model       : " + $item.Model)
        Write-Log ("RAM total   : " + (Format-Bytes ([double]$item.TotalPhysicalMemory)))
    }
    Write-Log ""
}

$cpu = Try-Cim "Win32_Processor"
if ($cpu) {
    Write-Log "== CPU =="
    foreach ($item in $cpu) {
        Write-Log ("Name       : " + $item.Name.Trim())
        Write-Log ("Vendor     : " + $item.Manufacturer)
        Write-Log ("Cores      : " + $item.NumberOfCores)
        Write-Log ("Threads    : " + $item.NumberOfLogicalProcessors)
        Write-Log ("Max clock  : " + $item.MaxClockSpeed + " MHz")
        Write-Log ("L2 cache   : " + $item.L2CacheSize + " KB")
        Write-Log ("L3 cache   : " + $item.L3CacheSize + " KB")
    }
    Write-Log ""
} else {
    try {
        $regCpu = Get-ItemProperty "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0" -ErrorAction Stop
        Write-Log "== CPU fallback =="
        Write-Log ("Name       : " + $regCpu.ProcessorNameString.Trim())
        Write-Log ("Vendor     : " + $regCpu.VendorIdentifier)
        Write-Log ("Clock      : " + $regCpu."~MHz" + " MHz")
        Write-Log ""
    } catch {}
}

$gpu = Try-Cim "Win32_VideoController"
if ($gpu) {
    Write-Log "== GPU =="
    foreach ($item in $gpu) {
        Write-Log ("Name       : " + $item.Name)
        Write-Log ("VRAM/WMI   : " + (Format-Bytes ([double]$item.AdapterRAM)))
        Write-Log ("Driver     : " + $item.DriverVersion)
        Write-Log ("Processor  : " + $item.VideoProcessor)
        if ($item.CurrentHorizontalResolution -and $item.CurrentVerticalResolution) {
            Write-Log ("Resolution : " + $item.CurrentHorizontalResolution + " x " + $item.CurrentVerticalResolution)
        }
        Write-Log ""
    }
}

$nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($nvidiaSmi) {
    Write-Log "== NVIDIA GPU via nvidia-smi =="
    try {
        $nvidia = & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>$null
        foreach ($line in $nvidia) {
            Write-Log $line
        }
    } catch {
        Write-Log ("[WARN] nvidia-smi failed: " + $_.Exception.Message)
    }
    Write-Log ""
}

$mem = Try-Cim "Win32_PhysicalMemory"
if ($mem) {
    Write-Log "== Memory modules =="
    foreach ($item in $mem) {
        Write-Log ("Slot       : " + $item.BankLabel + " / " + $item.DeviceLocator)
        Write-Log ("Maker      : " + $item.Manufacturer)
        Write-Log ("Part       : " + $item.PartNumber)
        Write-Log ("Capacity   : " + (Format-Bytes ([double]$item.Capacity)))
        Write-Log ("Speed      : " + $item.Speed + " MT/s")
        Write-Log ("Configured : " + $item.ConfiguredClockSpeed + " MT/s")
        Write-Log ""
    }
}

$disks = Try-Cim "Win32_DiskDrive"
if ($disks) {
    Write-Log "== Physical disks =="
    foreach ($item in $disks) {
        Write-Log ("Model      : " + $item.Model)
        Write-Log ("Media      : " + $item.MediaType)
        Write-Log ("Interface  : " + $item.InterfaceType)
        Write-Log ("Size       : " + (Format-Bytes ([double]$item.Size)))
        Write-Log ("Serial     : " + $item.SerialNumber)
        Write-Log ""
    }
}

try {
    $physicalDisks = Get-PhysicalDisk -ErrorAction Stop
    if ($physicalDisks) {
        Write-Log "== Physical disks via Storage cmdlets =="
        foreach ($item in $physicalDisks) {
            Write-Log ("Name       : " + $item.FriendlyName)
            Write-Log ("Media      : " + $item.MediaType)
            Write-Log ("Bus        : " + $item.BusType)
            Write-Log ("Size       : " + (Format-Bytes ([double]$item.Size)))
            Write-Log ("Health     : " + $item.HealthStatus)
            Write-Log ("Status     : " + ($item.OperationalStatus -join ", "))
            Write-Log ""
        }
    }
} catch {
    Write-Log ("[WARN] Cannot read Get-PhysicalDisk: " + $_.Exception.Message)
    Write-Log ""
}

$logical = Try-Cim "Win32_LogicalDisk"
if ($logical) {
    Write-Log "== Logical disks =="
    foreach ($item in ($logical | Where-Object { $_.DriveType -eq 3 })) {
        Write-Log ("Drive      : " + $item.DeviceID)
        Write-Log ("Label      : " + $item.VolumeName)
        Write-Log ("FS         : " + $item.FileSystem)
        Write-Log ("Size       : " + (Format-Bytes ([double]$item.Size)))
        Write-Log ("Free       : " + (Format-Bytes ([double]$item.FreeSpace)))
        if ($item.Size -and $item.FreeSpace) {
            Write-Log ("Free %     : " + ("{0:N1}%" -f (($item.FreeSpace / $item.Size) * 100)))
        }
        Write-Log ""
    }
}

try {
    $volumes = Get-Volume -ErrorAction Stop
    if ($volumes) {
        Write-Log "== Volumes via Storage cmdlets =="
        foreach ($item in $volumes) {
            Write-Log ("Drive      : " + $item.DriveLetter)
            Write-Log ("Label      : " + $item.FileSystemLabel)
            Write-Log ("FS         : " + $item.FileSystem)
            Write-Log ("Size       : " + (Format-Bytes ([double]$item.Size)))
            Write-Log ("Free       : " + (Format-Bytes ([double]$item.SizeRemaining)))
            Write-Log ("Health     : " + $item.HealthStatus)
            Write-Log ""
        }
    }
} catch {
    Write-Log ("[WARN] Cannot read Get-Volume: " + $_.Exception.Message)
    Write-Log ""
}

Write-Log ("[OK] System info written to: " + $logPath)
