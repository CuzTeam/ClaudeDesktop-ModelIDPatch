#Requires -RunAsAdministrator
param(
    [string]$ClaudeDesktopDir = ""
)
# patch-claude.ps1
# Patch Claude Desktop to allow non-Anthropic model names in enterprise config
# Step A: flip Electron fuse to disable asar integrity validation (in claude.exe)
# Step B: patch bLA() in app.asar to always return true (bypass model name check)
#
# Usage:
#   .\patch-claude.ps1
#   .\patch-claude.ps1 -ClaudeDesktopDir "C:\path\to\Claude_1.2.3_x64\app"
#
# Must run as Administrator (needed for takeown + icacls on WindowsApps dir)

$ErrorActionPreference = "Stop"

if ($ClaudeDesktopDir) {
    $appDir = $ClaudeDesktopDir.TrimEnd('\','/')
    if (-not (Test-Path $appDir)) {
        throw "Specified -ClaudeDesktopDir does not exist: $appDir"
    }
    Write-Host "Using specified directory: $appDir"
} else {
    # Auto-detect: find Claude_* under WindowsApps, pick the newest by name
    $windowsApps = "C:\Program Files\WindowsApps"
    $candidates = Get-ChildItem $windowsApps -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue |
                  Where-Object { Test-Path (Join-Path $_.FullName "app\claude.exe") } |
                  Sort-Object Name -Descending
    if (-not $candidates) {
        throw "No Claude_* installation found under $windowsApps. Use -ClaudeDesktopDir to specify the path manually."
    }
    if ($candidates.Count -gt 1) {
        Write-Host "Multiple Claude installations found, using newest:"
        $candidates | ForEach-Object { Write-Host "  $($_.Name)" }
    }
    $appDir = Join-Path $candidates[0].FullName "app"
    Write-Host "Auto-detected: $appDir"
}

$exePath    = Join-Path $appDir "claude.exe"
$asarPath   = Join-Path $appDir "resources\app.asar"
$tmpDir     = Join-Path $env:TEMP "claude_patch"
$jsPath     = Join-Path $tmpDir ".vite\build\index.js"
# Backups go to Desktop to avoid permission issues
$backupExe  = Join-Path $env:USERPROFILE "Desktop\claude.exe.bak"
$backupAsar = Join-Path $env:USERPROFILE "Desktop\app.asar.bak"

if (-not (Test-Path $exePath))  { throw "claude.exe not found at: $exePath" }
if (-not (Test-Path $asarPath)) { throw "app.asar not found at: $asarPath" }

# ── 1. Check / install asar ──────────────────────────────────────────────────
Write-Host "[1/8] Checking tools..."
$asarOk = $false
try { npx asar --version 2>&1 | Out-Null; $asarOk = $true } catch {}
if (-not $asarOk) {
    try { node --version | Out-Null } catch { throw "Node.js not found. Install it from https://nodejs.org first." }
    Write-Host "      asar not found, installing via npm..."
    npm install -g asar
    try { npx asar --version 2>&1 | Out-Null } catch { throw "asar install failed." }
    Write-Host "      asar installed."
} else {
    Write-Host "      asar OK."
}

# ── 2. Take ownership + grant write access ───────────────────────────────────
Write-Host "[2/8] Taking ownership and granting write access..."
takeown /F $exePath /A | Out-Null
icacls $exePath /grant "Administrators:(F)" | Out-Null
takeown /F $asarPath /A | Out-Null
icacls $asarPath /grant "Administrators:(F)" | Out-Null
Write-Host "      Done."

# ── 3. Backup ────────────────────────────────────────────────────────────────
Write-Host "[3/8] Backing up files to Desktop..."
if (Test-Path $backupExe) {
    Write-Host "      claude.exe.bak already exists, skipping."
} else {
    Copy-Item $exePath $backupExe
    Write-Host "      Saved claude.exe.bak"
}
if (Test-Path $backupAsar) {
    Write-Host "      app.asar.bak already exists, skipping."
} else {
    Copy-Item $asarPath $backupAsar
    Write-Host "      Saved app.asar.bak"
}

# ── 4. Flip Electron fuse: disable asar integrity validation ─────────────────
Write-Host "[4/8] Patching claude.exe — disabling asar integrity fuse..."

$exeBytes = [System.IO.File]::ReadAllBytes($exePath)

# Locate Electron fuse sentinel string
$sentinelStr   = "dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX"
$sentinelBytes = [System.Text.Encoding]::ASCII.GetBytes($sentinelStr)

$sentinelIdx = -1
for ($i = 0; $i -le $exeBytes.Length - $sentinelBytes.Length; $i++) {
    $match = $true
    for ($j = 0; $j -lt $sentinelBytes.Length; $j++) {
        if ($exeBytes[$i + $j] -ne $sentinelBytes[$j]) { $match = $false; break }
    }
    if ($match) { $sentinelIdx = $i; break }
}
if ($sentinelIdx -lt 0) { throw "Electron fuse sentinel not found in claude.exe." }

# Fuse wire layout (after sentinel):
#   [0] version byte
#   [1] cookie byte
#   [2] RunAsNode
#   [3] EnableCookieEncryption
#   [4] EnableNodeOptionsEnvironmentVariable
#   [5] EnableNodeCliInspectArguments
#   [6] EnableEmbeddedAsarIntegrityValidation  <-- flip ON(0x31) -> OFF(0x30)
#   [7] OnlyLoadAppFromAsar
#   ...
$fuseStart  = $sentinelIdx + $sentinelBytes.Length
$fuseOffset = $fuseStart + 6

$currentVal = $exeBytes[$fuseOffset]
Write-Host ("      Fuse byte at offset {0}: 0x{1:x2} ({2})" -f $fuseOffset, $currentVal, $(if ($currentVal -eq 0x31) {"ON"} else {"OFF"}))

if ($currentVal -eq 0x31) {
    $exeBytes[$fuseOffset] = 0x30
    [System.IO.File]::WriteAllBytes($exePath, $exeBytes)
    Write-Host "      Flipped to OFF (0x30)."
} else {
    Write-Host "      Already OFF, skipping."
}

# ── 5. Extract asar ──────────────────────────────────────────────────────────
Write-Host "[5/8] Extracting app.asar to $tmpDir ..."
if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
npx asar extract $asarPath $tmpDir

# ── 6. Patch index.js ────────────────────────────────────────────────────────
Write-Host "[6/8] Patching .vite/build/index.js ..."

$content = [System.IO.File]::ReadAllText($jsPath, [System.Text.Encoding]::UTF8)

# bLA() checks if a model name contains Anthropic keywords (claude/sonnet/opus/haiku/anthropic)
# Replacing with a stub that always returns true bypasses the model name restriction
$original = 'function bLA(e){const A=e.toLowerCase();return bxe.test(A)||ZWt.some(t=>A.includes(t))}'
$patched  = 'function bLA(e){return true/*patched*/}'

if ($content.IndexOf($original) -lt 0) {
    throw "Patch target not found in index.js. The app may have been updated — patch needs revision."
}
$count = ([regex]::Matches($content, [regex]::Escape($original))).Count
$newContent = $content.Replace($original, $patched)
[System.IO.File]::WriteAllText($jsPath, $newContent, [System.Text.Encoding]::UTF8)
Write-Host "      Replaced $count occurrence(s)."

# ── 7. Repack asar ───────────────────────────────────────────────────────────
Write-Host "[7/8] Repacking app.asar ..."
npx asar pack $tmpDir $asarPath

# ── 8. Cleanup ───────────────────────────────────────────────────────────────
Write-Host "[8/8] Cleaning up temp files ..."
Remove-Item $tmpDir -Recurse -Force

Write-Host ""
Write-Host "Done. Restart Claude Desktop for the patch to take effect."
Write-Host "Backups: $backupExe  |  $backupAsar"
Write-Host "To revert:"
Write-Host "  Copy-Item '$backupExe'  '$exePath'  -Force"
Write-Host "  Copy-Item '$backupAsar' '$asarPath' -Force"
