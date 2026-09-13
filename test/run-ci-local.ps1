# ============================================================
#  Local simulation of the GitHub Actions workflow assertions.
#  Runs the same checks the CI jobs run, on this machine
#  (Windows PowerShell 5.1 == the windows-latest job).
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

Push-Location $repoRoot
try {
    Write-Host ''
    Write-Host ("Repo   : " + $repoRoot)
    Write-Host ("Parser : " + $PSVersionTable.PSVersion.ToString())

    Step 'Show parser version' {
        if (-not $PSVersionTable.PSVersion) { throw 'no version info' }
    }

    Step 'Self-test (17 assertions)' {
        & $tests *> $null
        if ($LASTEXITCODE -ne 0) { throw "run-tests.ps1 exited $LASTEXITCODE" }
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
            $text = "# " + [char]0x4E2D + [char]0x6587 + "`nWrite-Host 'hi'`n"
            [System.IO.File]::WriteAllText($file, $text, (New-Object System.Text.UTF8Encoding($false)))

            & $guard -Path $dir -Json *> $null
            if ($LASTEXITCODE -ne 1) { throw "expected 1 (findings), got $LASTEXITCODE" }
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Step 'YAML workflow file is well-formed (indent + key checks)' {
        $wf = Join-Path $repoRoot '.github\workflows\check-encoding.yml'
        if (-not (Test-Path -LiteralPath $wf)) { throw 'workflow file missing' }
        $lines = Get-Content -LiteralPath $wf
        if ($lines.Count -lt 20) { throw 'workflow suspiciously short' }
        foreach ($needle in @('runs-on: windows-latest', 'runs-on: ubuntu-latest', 'shell: powershell', 'shell: pwsh')) {
            if (-not ($lines -match [regex]::Escape($needle))) { throw "missing: $needle" }
        }
        # Every tab is illegal in YAML
        if ($lines | Where-Object { $_ -match "`t" }) { throw 'YAML contains a tab character' }
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
