# ps1-encoding-guard

Detect and fix PowerShell scripts that contain non-ASCII characters but lack a UTF-8 BOM — the silent cause of "double-clicked script window closes instantly" on Windows.

## The problem

Windows PowerShell 5.1 parses script files as **ANSI** (e.g. CP936 on Chinese Windows), **not UTF-8**. So a file that is UTF-8 *without* a BOM gets mangled:

```powershell
# 推送两个仓库到 GitHub 私有库          <- what you wrote (UTF-8)
# 鎺ㄩ佷袱涓粨搴撳埌 GitHub 绉佹湁搴?     <- what PowerShell 5.1 sees (read as ANSI)
```

The mojibake breaks quote pairing, and the parser reports errors that look like **unbalanced brackets** — not like an encoding issue at all:

```
表达式或语句中包含意外的标记"...'; repo = 'image-game-archive' }"
哈希文本不完整。
字符串缺少终止符: "。
表达式或语句中缺少右")"。
```

Then, if you double-click the `.ps1`, the window closes before you can read anything. **The script appears broken; the code is actually fine.**

## The three safe combinations

| Script contains non-ASCII? | Encoding | Works? |
|---|---|---|
| No (pure ASCII) | UTF-8 without BOM | ✅ |
| Yes | UTF-8 **with BOM** | ✅ |
| Yes | UTF-8 **without BOM** | ❌ **breaks** |
| Yes | UTF-16 LE (Notepad "Unicode") | ✅ (PowerShell honors the BOM) |

## Usage

```powershell
# Dry run: report problems in the current directory
.\fix-ps1-encoding.ps1

# Scan a specific tree
.\fix-ps1-encoding.ps1 -Path D:\repos

# Actually add the BOM
.\fix-ps1-encoding.ps1 -Apply

# Machine-readable output (for CI)
.\fix-ps1-encoding.ps1 -Json
```

### Example output

```
Root    : D:\projects\my-repo
Mode    : DRY RUN
Scanned : 47 file(s)

Found 2 problem file(s):

  [BREAKS] projects\tools\gen.ps1
         non-ASCII=273  size=4738B  parse-errors=30
         表达式或语句中包含意外的标记"銆戝搴旂幇瀹炴湇瑁?"。
  [RISKY]  projects\services\start.ps1
         non-ASCII=45   size=477B   parse-errors=0
```

- **BREAKS** — already has parse errors; the script cannot run.
- **RISKY** — happens to parse today (non-ASCII only inside string literals), but any edit can break it.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | No problems, or all fixed |
| `1` | Problems found, not fixed (dry run) |
| `2` | Some files could not be fixed |

Useful for CI — fail the job when someone commits an unencoded script:

```yaml
# GitHub Actions runners default to Linux, which ships pwsh (7.x) only —
# there is no powershell.exe. Use the pwsh token / pwsh shell.
- run: pwsh -File ./fix-ps1-encoding.ps1 -Path ./scripts
```

A ready-to-use workflow, [`check-encoding.yml`](.github/workflows/check-encoding.yml),
runs on `windows-latest` so the check matches the real Windows PowerShell 5.1
parsing behaviour, plus a `linux` job that exercises the script under PowerShell 7.

## Options

| Parameter | Default | Description |
|---|---|---|
| `-Path` | `.` | Directory to scan recursively |
| `-Apply` | off | Add BOM to flagged files (otherwise dry run) |
| `-Json` | off | Emit a JSON report instead of text |
| `-SkipDir` | `node_modules`, `.git`, `.gradle`, `binaries`, `dist`, `build`, `vendor`, `.venv`, `venv` | Directory names to skip |

## What `-Apply` does

Only prepends the three BOM bytes (`EF BB BF`) — the file's text content is untouched:

```powershell
# read explicitly as UTF-8 (the file already is; it just lacks the BOM)
$text = [System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($true)))
#                                                            ^^^^ = write BOM
```

After each write the script re-checks the BOM and re-parses the file, so the report reflects the real post-fix state. Original non-ASCII content is preserved.

## Writing scripts that avoid this entirely

```powershell
# Safe: ASCII only — no BOM needed, works everywhere
# Push repos to GitHub
Write-Host 'pushing branch...'
```

If you need non-ASCII and generate files programmatically:

```powershell
# WRONG — UTF-8 without BOM
[System.IO.File]::WriteAllText($f, $text, (New-Object System.Text.UTF8Encoding($false)))

# RIGHT — UTF-8 with BOM
[System.IO.File]::WriteAllText($f, $text, (New-Object System.Text.UTF8Encoding($true)))
```

> Many editors, templates, and code generators default to **UTF-8 without BOM**, which is why this bites so often.

## Preventing the "window closes instantly" part

Regardless of encoding, a double-clicked `.ps1` closes its window when it finishes. Wrap it in a `.cmd` so failures stay visible:

```bat
@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0your-script.ps1"
echo.
echo Finished. Window stays open.
pause
```

`-NoExit` keeps PowerShell alive; `pause` stops the wrapper from closing too.

## Tests

```powershell
.\test\run-tests.ps1
```

Creates fixtures in a temp directory and asserts detection, directory skipping, exit codes, BOM writing, content preservation, and BREAKS classification. 17 assertions, no external dependencies.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- No external dependencies

The bug is specific to **Windows PowerShell 5.1**. PowerShell 7+ defaults to UTF-8 for script parsing and does not suffer from it — but adding a BOM remains harmless and keeps scripts portable back to 5.1.

## License

MIT — see [LICENSE](LICENSE).
