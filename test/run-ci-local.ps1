# ============================================================
#  Local simulation of the GitHub Actions workflow assertions.
#  Runs the same checks CI runs, on this machine.
#
#  On Windows this exercises Windows PowerShell 5.1 — the exact parser
#  the windows-latest job uses, so that authoritative job is fully
#  reproducible locally.
#
#  Usage:  .\test\run-ci-local.ps1
#  Exit codes: 0 = all assertions held, 1 = at least one failed
# ============================================================

$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path $PSScriptRoot -Parent
$guard    = Join-Path $repoRoot 'fix-ps1-encoding.ps1'
$tests    = Join-Path $repoRoot 'test\run-tests.ps1'

$pass = 0
$fail = 0

function Step {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ''
    Write-Host ("--- " + $Name + " ---") -ForegroundColor Cyan
    try {
        & $Body
        Write-Host ("  OK   " + $Name) -ForegroundColor Green
        $script:pass++
    } catch {
        Write-Host ("  FAIL " + $Name + "  -> " + $_.Exception.Message) -ForegroundColor Red
        $script:fail++
    }
}

function New-Utf8NoBomFile {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

Push-Location $repoRoot
try {
    Write-Host ''
    Write-Host ("Repo   : " + $repoRoot)
    Write-Host ("Parser : " + $PSVersionTable.PSVersion.ToString())
    Write-Host ("EA pref: " + $ErrorActionPreference)

    Step 'Show parser version' {
        if (-not $PSVersionTable.PSVersion) { throw 'no version info' }
    }

    Step 'Self-test (17 assertions)' {
        # run-tests.ps1 throws on failure and does not call `exit`,
        # so a thrown exception is the only failure signal.
        & $tests *> $null
    }

    Step 'Scan repo expects exit 0 (clean)' {
        & $guard -Path . -Json *> $null
        if ($LASTEXITCODE -ne 0) { throw "expected 0, got $LASTEXITCODE" }
    }

    Step '-Apply is a no-op on a clean tree' {
        & $guard -Path . -Apply -Json *> $null
        if ($LASTEXITCODE -ne 0) { throw "expected 0 after -Apply, got $LASTEXITCODE" }
    }

    Step 'git status clean after -Apply' {
        $changes = @(git status --porcelain)
        if ($changes.Count -gt 0) {
            throw ("working tree dirty: " + ($changes -join ' | '))
        }
    }

    Step 'Detect deliberately broken fixture (expect exit 1)' {
        $dir = Join-Path $env:TEMP ('ci-local-fixture-' + (Get-Date -Format 'HHmmss'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            $file = Join-Path $dir 'needs-bom.ps1'
            New-Utf8NoBomFile -Path $file -Content "# $([char]0x4E2D)$([char]0x6587)`nWrite-Host 'hi'`n"

            & $guard -Path $dir -Json *> $null
            if ($LASTEXITCODE -ne 1) { throw "expected 1 (findings), got $LASTEXITCODE" }
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Step 'YAML workflow is well-formed (keys + no tabs)' {
        $wf = Join-Path $repoRoot '.github\workflows\check-encoding.yml'
        if (-not (Test-Path -LiteralPath $wf)) { throw 'workflow file missing' }
        $lines = Get-Content -LiteralPath $wf
        if ($lines.Count -lt 20) { throw 'workflow suspiciously short' }
        foreach ($needle in @('runs-on: windows-latest', 'runs-on: ubuntu-latest', 'shell: powershell', 'shell: pwsh')) {
            if (-not ($lines -match [regex]::Escape($needle))) { throw "missing: $needle" }
        }
        if ($lines | Where-Object { $_ -match "`t" }) { throw 'YAML contains a tab character' }
    }

    # ----------------------------------------------------------------
    # Cross-platform guards.
    #
    # These exist because a hardcoded '\' in a test assertion passed on
    # Windows but failed on the Linux runner. A local Windows run cannot
    # execute under Linux, so instead we statically forbid the pattern
    # and verify the path-normalization contract directly.
    # ----------------------------------------------------------------
    Step 'No hardcoded backslash as path separator in comparisons' {
        $suspect = @()
        Get-ChildItem -LiteralPath $repoRoot -Recurse -Force -File -Filter '*.ps1' |
            Where-Object { $_.FullName -notmatch '\\\.git\\' } |
            ForEach-Object {
                $n = 0
                foreach ($line in (Get-Content -LiteralPath $_.FullName)) {
                    $n++
                    if ($line -match "-contains\s+'[^']*\\\w" -or $line -match "-eq\s+'[^']*\\\w") {
                        $suspect += ("{0}:{1}" -f $_.Name, $n)
                    }
                }
            }
        if ($suspect.Count -gt 0) {
            throw ("hardcoded separator in comparison -> " + ($suspect -join ', '))
        }
    }

    Step 'Relative paths normalize to forward slashes' {
        $dir = Join-Path $env:TEMP ('ci-rel-' + (Get-Date -Format 'HHmmssfff'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            $sub = Join-Path $dir 'sub'
            New-Item -ItemType Directory -Path $sub -Force | Out-Null
            New-Utf8NoBomFile -Path (Join-Path $sub 'x.ps1') -Content "# $([char]0x4E2D)`n"

            $json = & $guard -Path $dir -Json | ConvertFrom-Json
            $norm = $json.findings[0].Relative -replace '\\', '/'
            if ($norm -ne 'sub/x.ps1') { throw "expected 'sub/x.ps1', got '$norm'" }
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Step '.gitattributes normalizes line endings' {
        $ga = Join-Path $repoRoot '.gitattributes'
        if (-not (Test-Path -LiteralPath $ga)) { throw '.gitattributes missing' }
        $text = Get-Content -LiteralPath $ga -Raw
        if ($text -notmatch 'text=auto') { throw 'missing text=auto' }
        if ($text -notmatch 'eol=lf') { throw 'missing eol=lf' }
    }
} finally {
    Pop-Location
}

Write-Host ''
Write-Host '================================================' -ForegroundColor Cyan
Write-Host ("  Passed: $pass   Failed: $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host '================================================' -ForegroundColor Cyan
Write-Host ''

exit $(if ($fail -eq 0) { 0 } else { 1 })
