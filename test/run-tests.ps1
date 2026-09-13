# ============================================================
#  Self-test for fix-ps1-encoding.ps1
#  Creates fixtures (good + bad scripts), runs the guard against
#  them, and asserts the detection result. ASCII-only on purpose.
#
#  Usage:
#     .\test\run-tests.ps1
#
#  Exit codes: 0 = all passed, 1 = failures
# ============================================================

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$guard    = Join-Path $repoRoot 'fix-ps1-encoding.ps1'

if (-not (Test-Path -LiteralPath $guard)) { throw "Guard script not found: $guard" }

$tmp = Join-Path $env:TEMP ('ps1-encoding-guard-test-' + (Get-Date -Format 'yyyyMMddHHmmss'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

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

try {
    Write-Host ''
    Write-Host "Fixtures: $tmp"
    Write-Host ''

    # ---- fixture 1: ASCII only, no BOM  -> should NOT be flagged ----
    $f1 = Join-Path $tmp 'good-ascii.ps1'
    [System.IO.File]::WriteAllText($f1, "# ascii only`nWrite-Host 'ok'`n", $utf8NoBom)

    # ---- fixture 2: non-ASCII + BOM     -> should NOT be flagged ----
    $f2 = Join-Path $tmp 'good-bom.ps1'
    [System.IO.File]::WriteAllText($f2, "# note with non-ascii: cafe`nWrite-Host 'ok'`n".Replace('cafe', [char]0x5496 + [char]0x5561) + "`n", $utf8Bom)

    # ---- fixture 3: non-ASCII, no BOM   -> should be flagged ----
    $f3 = Join-Path $tmp 'bad-no-bom.ps1'
    [System.IO.File]::WriteAllText($f3, "# " + [char]0x4E2D + [char]0x6587 + "`nWrite-Host 'ok'`n", $utf8NoBom)

    # ---- fixture 4: non-ASCII, no BOM, in a skipped dir -> NOT flagged ----
    $skipDir = Join-Path $tmp 'node_modules'
    New-Item -ItemType Directory -Path $skipDir -Force | Out-Null
    $f4 = Join-Path $skipDir 'ignored.ps1'
    [System.IO.File]::WriteAllText($f4, "# " + [char]0x4E2D + [char]0x6587 + "`n", $utf8NoBom)

    Write-Host '=== Test 1: dry run detection ===' -ForegroundColor Cyan
    $json1 = & $guard -Path $tmp -Json | ConvertFrom-Json
    $rel = @($json1.findings | ForEach-Object { $_.Relative })

    Assert 'flags bad-no-bom.ps1'                ($rel -contains 'bad-no-bom.ps1')  ('got: ' + ($rel -join ', '))
    Assert 'does not flag good-ascii.ps1'        (-not ($rel -contains 'good-ascii.ps1'))
    Assert 'does not flag good-bom.ps1'          (-not ($rel -contains 'good-bom.ps1'))
    Assert 'skips node_modules'                  (-not ($rel -contains 'node_modules\ignored.ps1'))
    Assert 'exactly 1 finding'                   ($json1.findings.Count -eq 1)      ('got ' + $json1.findings.Count)
    Assert 'mode is dry-run'                     ($json1.mode -eq 'dry-run')
    Assert 'scanned counts 3 visible files'      ($json1.scanned -eq 3)            ('got ' + $json1.scanned)

    Write-Host ''
    Write-Host '=== Test 2: dry run exit code should be 1 ===' -ForegroundColor Cyan
    & $guard -Path $tmp *> $null
    Assert 'exit code 1 when problems unfixed'   ($LASTEXITCODE -eq 1)              ('got ' + $LASTEXITCODE)

    Write-Host ''
    Write-Host '=== Test 3: -Apply fixes the file ===' -ForegroundColor Cyan
    $json2 = & $guard -Path $tmp -Apply -Json | ConvertFrom-Json
    # Assign first: nesting a pipeline inside @() mis-binds on some PS 5.1 builds
    $fixedList = @($json2.findings | Where-Object { $_.Fixed })
    Assert 'reports 1 fixed'                     ($fixedList.Count -eq 1)           ('got ' + $fixedList.Count)
    Assert 'all findings parsed'                 (@($json2.findings).Count -eq 1)   ('got ' + @($json2.findings).Count)
    Assert 'exit code 0 after fix'               ($LASTEXITCODE -eq 0)              ('got ' + $LASTEXITCODE)

    $bytes = [System.IO.File]::ReadAllBytes($f3)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert 'file now has UTF-8 BOM'              $hasBom

    # content preserved (non-ascii chars intact)
    $text = [System.IO.File]::ReadAllText($f3, (New-Object System.Text.UTF8Encoding($false)))
    Assert 'non-ascii content preserved'         ($text.Contains([string]([char]0x4E2D + [char]0x6587)))

    Write-Host ''
    Write-Host '=== Test 4: re-scan should be clean ===' -ForegroundColor Cyan
    $json3 = & $guard -Path $tmp -Json | ConvertFrom-Json
    Assert 'no findings after fix'               ($json3.findings.Count -eq 0)      ('got ' + $json3.findings.Count)
    Assert 'exit code 0 when clean'              ($LASTEXITCODE -eq 0)             ('got ' + $LASTEXITCODE)

    Write-Host ''
    Write-Host '=== Test 5: auto-detect a broken (unparseable) file ===' -ForegroundColor Cyan
    $f5 = Join-Path $tmp 'broken.ps1'
    # Unterminated string -> real parse error; with non-ascii + no BOM it becomes "BREAKS"
    [System.IO.File]::WriteAllText($f5, "# " + [char]0x4E2D + [char]0x6587 + "`n$s = 'unterminated`n", $utf8NoBom)
    $json4 = & $guard -Path $tmp -Json | ConvertFrom-Json
    $b = $json4.findings | Where-Object { $_.Relative -eq 'broken.ps1' }
    Assert 'detects broken.ps1'                  ($null -ne $b)
    if ($b) { Assert 'status is BREAKS'          ($b.Status -eq 'BREAKS')           ('got ' + $b.Status) }
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '================================================' -ForegroundColor Cyan
Write-Host ("  Passed: $pass   Failed: $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host '================================================' -ForegroundColor Cyan
Write-Host ''

exit $(if ($fail -eq 0) { 0 } else { 1 })
