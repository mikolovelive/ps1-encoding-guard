# ============================================================
#  Self-test for fix-ps1-encoding.ps1
#
#  Creates fixtures (good/bad/skipped scripts), runs the guard against
#  them out-of-process, and asserts the reported findings.
#
#  Portability + CI rules baked in:
#
#   1. Temp dir via [System.IO.Path]::GetTempPath()
#      ($env:TEMP is Windows-only; Linux/macOS runners set TMPDIR instead.)
#
#   2. The guard is launched with the call operator and its code read from
#      $LASTEXITCODE. The guard ends with `exit N` by design (it is a lint
#      tool and its exit code is part of its public contract), so we must
#      read that code rather than let it escape.
#
#   3. This file does NOT call `exit`. It reports failure by throwing, so it
#      is safe to call from a CI step that is executed via
#      `powershell -command ". 'step.ps1'"` (dot-sourcing). An `exit` here
#      would abort the calling step with a confusing exit code.
#
#  Usage:  .\test\run-tests.ps1
#  Throws on failure; returns normally on success.
# ============================================================

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$guard    = Join-Path $repoRoot 'fix-ps1-encoding.ps1'

if (-not (Test-Path -LiteralPath $guard)) { throw "Guard script not found: $guard" }

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps1-encoding-guard-test-' + (Get-Date -Format 'yyyyMMddHHmmss'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$utf8Bom   = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$pass = 0
$fail = 0

function Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("  PASS  " + $Name) -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host ("  FAIL  " + $Name + $(if ($Detail) { '  -> ' + $Detail } else { '' })) -ForegroundColor Red
        $script:fail++
    }
}

# Run the guard and capture both its JSON report and its exit code.
function Invoke-Guard {
    param([string]$Path, [switch]$Apply)

    $tmpJson = Join-Path $testRoot ('guard-' + [Guid]::NewGuid().ToString('N') + '.json')

    $global:LASTEXITCODE = 0
    if ($Apply) {
        & $guard -Path $Path -Apply -Json *> $tmpJson
    } else {
        & $guard -Path $Path -Json *> $tmpJson
    }
    $code = $global:LASTEXITCODE

    $json = $null
    if (Test-Path -LiteralPath $tmpJson) {
        $raw = Get-Content -LiteralPath $tmpJson -Raw -Encoding UTF8
        # The guard writes only JSON to stdout, but be tolerant of stray lines.
        if ($raw) {
            $start = $raw.IndexOf('{')
            if ($start -ge 0) {
                try { $json = $raw.Substring($start) | ConvertFrom-Json } catch { }
            }
        }
    }
    return [pscustomobject]@{ ExitCode = $code; Json = $json }
}

try {
    Write-Host ''
    Write-Host ("Fixtures: " + $testRoot)
    Write-Host ("Parser  : " + $PSVersionTable.PSVersion.ToString())
    Write-Host ''

    $cjk = [string]([char]0x4E2D + [char]0x6587)

    # fixture 1: ASCII only, no BOM -> must NOT be flagged
    [System.IO.File]::WriteAllText((Join-Path $testRoot 'good-ascii.ps1'),
        "# ascii only`nWrite-Host 'ok'`n", $utf8NoBom)

    # fixture 2: non-ASCII + BOM -> must NOT be flagged
    [System.IO.File]::WriteAllText((Join-Path $testRoot 'good-bom.ps1'),
        ("# note: " + $cjk + "`nWrite-Host 'ok'`n"), $utf8Bom)

    # fixture 3: non-ASCII, no BOM -> MUST be flagged
    $f3 = Join-Path $testRoot 'bad-no-bom.ps1'
    [System.IO.File]::WriteAllText($f3, ("# " + $cjk + "`nWrite-Host 'ok'`n"), $utf8NoBom)

    # fixture 4: same as 3 but inside a skipped directory -> must NOT be flagged
    $skipDir = Join-Path $testRoot 'node_modules'
    New-Item -ItemType Directory -Path $skipDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $skipDir 'ignored.ps1'), ("# " + $cjk + "`n"), $utf8NoBom)

    Write-Host '=== Test 1: dry run detection ===' -ForegroundColor Cyan
    $r1 = Invoke-Guard -Path $testRoot
    if (-not $r1.Json) { throw 'guard produced no parseable JSON on the dry run' }
    $json1 = $r1.Json
    # Normalize separators: Relative uses '/' on Linux and '\' on Windows.
    $rel = @($json1.findings | ForEach-Object { $_.Relative -replace '\\', '/' })

    Assert 'exit code 1 when findings present'   ($r1.ExitCode -eq 1)              ('got ' + $r1.ExitCode)
    Assert 'flags bad-no-bom.ps1'                ($rel -contains 'bad-no-bom.ps1')  ('got: ' + ($rel -join ', '))
    Assert 'does not flag good-ascii.ps1'        (-not ($rel -contains 'good-ascii.ps1'))
    Assert 'does not flag good-bom.ps1'          (-not ($rel -contains 'good-bom.ps1'))
    Assert 'skips node_modules'                  (-not ($rel -contains 'node_modules/ignored.ps1'))
    Assert 'exactly 1 finding'                   (@($json1.findings).Count -eq 1)   ('got ' + @($json1.findings).Count)
    Assert 'mode is dry-run'                     ($json1.mode -eq 'dry-run')
    Assert 'scanned counts 3 visible files'      ($json1.scanned -eq 3)            ('got ' + $json1.scanned)

    Write-Host ''
    Write-Host '=== Test 2: -Apply fixes the file ===' -ForegroundColor Cyan
    $r2 = Invoke-Guard -Path $testRoot -Apply
    if (-not $r2.Json) { throw 'guard produced no parseable JSON after -Apply' }
    $fixedList = @($r2.Json.findings | Where-Object { $_.Fixed })

    Assert 'exit code 0 after fix'               ($r2.ExitCode -eq 0)              ('got ' + $r2.ExitCode)
    Assert 'reports 1 fixed'                     ($fixedList.Count -eq 1)          ('got ' + $fixedList.Count)
    Assert 'all findings parsed'                 (@($r2.Json.findings).Count -eq 1) ('got ' + @($r2.Json.findings).Count)

    $bytes = [System.IO.File]::ReadAllBytes($f3)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert 'file now has UTF-8 BOM'              $hasBom

    $text = [System.IO.File]::ReadAllText($f3, $utf8NoBom)
    Assert 'non-ascii content preserved'         ($text.Contains($cjk))

    Write-Host ''
    Write-Host '=== Test 3: re-scan should be clean ===' -ForegroundColor Cyan
    $r3 = Invoke-Guard -Path $testRoot
    Assert 'exit code 0 when clean'              ($r3.ExitCode -eq 0)              ('got ' + $r3.ExitCode)
    Assert 'no findings after fix'               (@($r3.Json.findings).Count -eq 0) ('got ' + @($r3.Json.findings).Count)

    Write-Host ''
    Write-Host '=== Test 4: detect a broken (unparseable) file ===' -ForegroundColor Cyan
    $f5 = Join-Path $testRoot 'broken.ps1'
    # Unterminated string -> genuine parse error, combined with non-ASCII + no BOM.
    [System.IO.File]::WriteAllText($f5, ("# " + $cjk + "`n`$s = 'unterminated`n"), $utf8NoBom)
    $r4 = Invoke-Guard -Path $testRoot
    $b = @($r4.Json.findings) | Where-Object { ($_.Relative -replace '\\', '/') -eq 'broken.ps1' }
    Assert 'detects broken.ps1'                  ($null -ne $b)
    if ($b) { Assert 'status is BREAKS'          ($b.Status -eq 'BREAKS')          ('got ' + $b.Status) }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '================================================' -ForegroundColor Cyan
Write-Host ("  Passed: $pass   Failed: $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host '================================================' -ForegroundColor Cyan
Write-Host ''

# No `exit` here on purpose: this file may be dot-sourced by a CI step.
# Report failure by throwing, which the caller turns into a non-zero exit.
if ($fail -gt 0) {
    throw "$fail assertion(s) failed"
}
