# ============================================================
#  fix-ps1-encoding.ps1
#
#  Detect and fix PowerShell scripts (.ps1 / .psm1 / .psd1) that
#  contain non-ASCII characters but lack a UTF-8 BOM.
#
#  Why it matters: Windows PowerShell 5.1 parses script files as
#  ANSI (e.g. CP936 on Chinese Windows), not UTF-8. A UTF-8 file
#  WITHOUT a BOM therefore gets mangled: Chinese/Japanese text turns
#  into mojibake, quote pairing breaks, and the parser reports bogus
#  "syntax error" messages. Run by double-click, the window then
#  closes instantly so the user sees nothing at all.
#
#  This script reports such files and, with -Apply, adds the BOM.
#
#  Usage:
#     .\fix-ps1-encoding.ps1                    # scan current dir (dry run)
#     .\fix-ps1-encoding.ps1 -Path D:\repo      # scan another directory
#     .\fix-ps1-encoding.ps1 -Apply             # actually add BOM
#     .\fix-ps1-encoding.ps1 -Apply -Json       # machine-readable report
#
#  Exit codes:
#     0 = no problems found, or all fixed successfully
#     1 = problems found and NOT fixed (dry run)
#     2 = some files could not be fixed
#
#  License: MIT
# ============================================================

[CmdletBinding()]
param(
    [string]$Path = '.',
    [switch]$Apply,
    [switch]$Json,
    [string[]]$SkipDir = @('node_modules', '.git', '.gradle', 'binaries', 'dist', 'build', 'vendor', '.venv', 'venv')
)

$ErrorActionPreference = 'Stop'

$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Test-HasBom {
    param([byte[]]$Bytes)
    return ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
}

function Get-ParseError {
    param([string]$File)
    $errors = $null
    try {
        [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$errors) | Out-Null
    } catch {
        return @('<parser threw: ' + $_.Exception.Message + '>')
    }
    if ($errors -and $errors.Count -gt 0) {
        return @($errors | ForEach-Object { $_.Message })
    }
    return @()
}

# ------------------------------------------------------------
# Resolve root
# ------------------------------------------------------------
$rootItem = Get-Item -LiteralPath $Path -ErrorAction Stop
if (-not $rootItem.PSIsContainer) { throw "Not a directory: $Path" }
$root = $rootItem.FullName

# ------------------------------------------------------------
# Scan
# ------------------------------------------------------------
$findings = New-Object System.Collections.Generic.List[object]
$scanned = 0

Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } |
    ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
        foreach ($seg in ($rel -split '[\\/]')) {
            if ($SkipDir -contains $seg) { return }
        }

        $scanned++
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        if (Test-HasBom -Bytes $bytes) { return }

        $nonAscii = 0
        foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++ } }
        if ($nonAscii -eq 0) { return }

        $errs = Get-ParseError -File $_.FullName
        $findings.Add([pscustomobject]@{
            Path       = $_.FullName
            Relative   = $rel
            NonAscii   = $nonAscii
            SizeBytes  = $bytes.Length
            ErrorCount = $errs.Count
            Errors     = $errs
            Status     = if ($errs.Count -gt 0) { 'BREAKS' } else { 'RISKY' }
            Fixed      = $false
        })
    }

# ------------------------------------------------------------
# Apply
# ------------------------------------------------------------
$failed = 0

if ($Apply -and $findings.Count -gt 0) {
    foreach ($f in $findings) {
        try {
            $text = [System.IO.File]::ReadAllText($f.Path, $Utf8NoBom)
            [System.IO.File]::WriteAllText($f.Path, $text, $Utf8Bom)

            $after = [System.IO.File]::ReadAllBytes($f.Path)
            $errs2 = Get-ParseError -File $f.Path
            $f.Fixed = (Test-HasBom -Bytes $after) -and ($errs2.Count -eq 0)
            $f.ErrorCount = $errs2.Count
            $f.Errors = $errs2
            $f.SizeBytes = $after.Length
            if (-not $f.Fixed) { $failed++ }
        } catch {
            $failed++
        }
    }
}

# ------------------------------------------------------------
# Report
# ------------------------------------------------------------
if ($Json) {
    [pscustomobject]@{
        root     = $root
        scanned  = $scanned
        mode     = if ($Apply) { 'apply' } else { 'dry-run' }
        findings = $findings
        failed   = $failed
    } | ConvertTo-Json -Depth 4
} else {
    Write-Host ''
    Write-Host "Root    : $root"
    Write-Host ("Mode    : " + $(if ($Apply) { 'APPLY' } else { 'DRY RUN' }))
    Write-Host "Scanned : $scanned file(s)"
    Write-Host ''

    if ($findings.Count -eq 0) {
        Write-Host 'OK - no non-ASCII script without BOM found.' -ForegroundColor Green
    } else {
        Write-Host ("Found " + $findings.Count + " problem file(s):") -ForegroundColor Yellow
        Write-Host ''
        foreach ($f in ($findings | Sort-Object ErrorCount -Descending)) {
            $tag = if ($f.Fixed) { 'FIXED' } else { $f.Status }
            $color = switch ($tag) { 'FIXED' { 'Green' } 'BREAKS' { 'Red' } default { 'Yellow' } }
            Write-Host ("  [$tag] " + $f.Relative) -ForegroundColor $color
            Write-Host ("         non-ASCII=" + $f.NonAscii + "  size=" + $f.SizeBytes + "B  parse-errors=" + $f.ErrorCount) -ForegroundColor DarkGray
            foreach ($e in ($f.Errors | Select-Object -First 3)) {
                Write-Host ("         " + $e) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
        if (-not $Apply) {
            Write-Host 'Nothing changed. Re-run with -Apply to add the BOM.' -ForegroundColor Yellow
        } elseif ($failed -gt 0) {
            Write-Host ("Fixed " + ($findings.Count - $failed) + " / " + $findings.Count + "; " + $failed + " failed.") -ForegroundColor Red
        } else {
            Write-Host ("Fixed all " + $findings.Count + " file(s).") -ForegroundColor Green
        }
    }
    Write-Host ''
}

if ($findings.Count -eq 0) { exit 0 }
if (-not $Apply) { exit 1 }
if ($failed -gt 0) { exit 2 }
exit 0
