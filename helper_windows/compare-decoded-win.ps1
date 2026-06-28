param(
    [Parameter(Mandatory = $true)][string]$Reference,
    [Parameter(Mandatory = $true)][string]$Candidate,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$ResultFile
)

$ErrorActionPreference = "Stop"
$diff = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $Reference)) {
    $diff.Add("reference missing: $Reference")
}
if (-not (Test-Path -LiteralPath $Candidate)) {
    $diff.Add("output missing: $Candidate")
}

if ($diff.Count -eq 0) {
    $Reference = (Resolve-Path -LiteralPath $Reference).Path
    $Candidate = (Resolve-Path -LiteralPath $Candidate).Path

    $referenceFileCount = @(Get-ChildItem -LiteralPath $Reference -Recurse -File -Force).Count
    $candidateFileCount = @(Get-ChildItem -LiteralPath $Candidate -Recurse -File -Force).Count
    if ($referenceFileCount -eq 0) {
        $diff.Add("reference has no files: $Reference")
    }
    if ($candidateFileCount -eq 0) {
        $diff.Add("output has no files: $Candidate")
    }
}

function Get-RelativePath([string]$Root, [string]$Path) {
    return $Path.Substring($Root.Length).TrimStart("\")
}

if ($diff.Count -eq 0) {
    foreach ($refDir in Get-ChildItem -LiteralPath $Reference -Recurse -Directory) {
        $rel = Get-RelativePath $Reference $refDir.FullName
        if ($rel -and -not (Test-Path -LiteralPath (Join-Path $Candidate $rel))) {
            $diff.Add("Only in reference: $rel")
        }
    }

    foreach ($candDir in Get-ChildItem -LiteralPath $Candidate -Recurse -Directory) {
        $rel = Get-RelativePath $Candidate $candDir.FullName
        if ($rel -and -not (Test-Path -LiteralPath (Join-Path $Reference $rel))) {
            $diff.Add("Only in output: $rel")
        }
    }

    foreach ($refFile in Get-ChildItem -LiteralPath $Reference -Recurse -File) {
        $rel = Get-RelativePath $Reference $refFile.FullName
        $candFile = Join-Path $Candidate $rel
        if (-not (Test-Path -LiteralPath $candFile)) {
            $diff.Add("Only in reference: $rel")
            continue
        }
        $refHash = Get-FileHash -Algorithm SHA256 -LiteralPath $refFile.FullName
        $candHash = Get-FileHash -Algorithm SHA256 -LiteralPath $candFile
        if ($refHash.Hash -ne $candHash.Hash) {
            $diff.Add("Files differ: $rel")
        }
    }

    foreach ($candFile in Get-ChildItem -LiteralPath $Candidate -Recurse -File) {
        $rel = Get-RelativePath $Candidate $candFile.FullName
        $refFile = Join-Path $Reference $rel
        if (-not (Test-Path -LiteralPath $refFile)) {
            $diff.Add("Only in output: $rel")
        }
    }
}

if ($diff.Count -eq 0) {
    Write-Output "[PASS] $Name"
    "==> Verify: PASS" | Out-File -Append -Encoding UTF8 -LiteralPath $ResultFile
    exit 0
}

Write-Output "[FAIL] $Name"
$diff | Select-Object -First 50 | ForEach-Object { Write-Output ("  " + $_) }
"==> Verify: FAIL" | Out-File -Append -Encoding UTF8 -LiteralPath $ResultFile
"==> Verify diff:" | Out-File -Append -Encoding UTF8 -LiteralPath $ResultFile
$diff | Select-Object -First 50 | Out-File -Append -Encoding UTF8 -LiteralPath $ResultFile
exit 1
