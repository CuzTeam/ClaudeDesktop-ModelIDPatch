#Requires -RunAsAdministrator
param(
    [string]$ClaudeDesktopDir = ""
)
# patch-claude.ps1
# Patch Claude Desktop to allow non-Anthropic model names in enterprise config
# Step A: flip Electron fuse to disable asar integrity validation (in claude.exe)
# Step B: patch model validation function in app.asar to always return true
#
# Supports remote patch definitions — fetches latest targets from GitHub.
#
# Usage:
#   .\patch-claude.ps1
#   .\patch-claude.ps1 -ClaudeDesktopDir "C:\path\to\Claude_1.2.3_x64\app"
#
# Must run as Administrator (needed for takeown + icacls on WindowsApps dir)

$ErrorActionPreference = "Stop"

$RemoteUrl = "https://raw.githubusercontent.com/CuzTeam/ClaudeDesktop-ModelIDPatch/refs/heads/main/patch-definitions.json"

# ── Embedded fallback definitions ────────────────────────────────────────────
$EmbeddedDefs = @{
    "1.6608.0" = @{
        original = 'function bLA(e){const A=e.toLowerCase();return bxe.test(A)||ZWt.some(t=>A.includes(t))}'
        patched  = 'function bLA(e){return true/*patched*/}'
    }
    "1.6608.2" = @{
        original = 'function ObA(e){const A=e.toLowerCase();return Yxe.test(A)||t5t.some(t=>A.includes(t))}'
        patched  = 'function ObA(e){return true/*patched*/}'
    }
}
$FallbackPatterns = @(
    'function \w{2,5}\(e\)\{const A=e\.toLowerCase\(\);return \w{2,5}\.test\(A\)\?!1:\w{2,5}\.test\(A\)\|\|\w{2,5}\.some\(t=>A\.includes\(t\)\)\}'
    'function \w{2,5}\(e\)\{const A=e\.toLowerCase\(\);return \w{2,5}\.test\(A\)\|\|\w{2,5}\.some\(t=>A\.includes\(t\)\)\}'
)

# ── Locate installation ──────────────────────────────────────────────────────
if ($ClaudeDesktopDir) {
    $appDir = $ClaudeDesktopDir.TrimEnd('\','/')
    if (-not (Test-Path $appDir)) {
        throw "Specified -ClaudeDesktopDir does not exist: $appDir"
    }
    Write-Host "Using specified directory: $appDir"
} else {
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

# ── Detect version ───────────────────────────────────────────────────────────
$versionMatch = [regex]::Match($appDir, 'Claude_(\d+\.\d+\.\d+)')
$claudeVersion = if ($versionMatch.Success) { $versionMatch.Groups[1].Value } else { "unknown" }
Write-Host "Detected Claude Desktop version: $claudeVersion"

$exePath    = Join-Path $appDir "claude.exe"
$asarPath   = Join-Path $appDir "resources\app.asar"
$tmpDir     = Join-Path $env:TEMP "claude_patch"
$jsPath     = Join-Path $tmpDir ".vite\build\index.js"
$backupExe  = Join-Path $env:USERPROFILE "Desktop\claude.exe.bak"
$backupAsar = Join-Path $env:USERPROFILE "Desktop\app.asar.bak"

if (-not (Test-Path $exePath))  { throw "claude.exe not found at: $exePath" }
if (-not (Test-Path $asarPath)) { throw "app.asar not found at: $asarPath" }

# ── Fetch remote patch definitions ───────────────────────────────────────────
function Get-PatchDefinition {
    param([string]$Version)

    # Try remote first
    try {
        Write-Host "Fetching patch definitions from remote..."
        $json = Invoke-RestMethod -Uri $RemoteUrl -TimeoutSec 10
        $verDef = $json.definitions.$Version
        if ($verDef) {
            Write-Host "  Found remote definition for version $Version"
            return @{
                original = $verDef.windows.original
                patched  = $verDef.windows.patched
            }
        }
        Write-Host "  No exact match for $Version in remote, will try fallback"
        $patterns = if ($json.fallback_patterns) { $json.fallback_patterns } elseif ($json.fallback_pattern) { @($json.fallback_pattern) } else { $null }
        return @{ use_fallback = $true; remote_patterns = $patterns }
    } catch {
        Write-Host "  Remote fetch failed: $($_.Exception.Message)"
    }

    # Embedded fallback
    if ($EmbeddedDefs.ContainsKey($Version)) {
        Write-Host "  Using embedded definition for $Version"
        return $EmbeddedDefs[$Version]
    }

    return @{ use_fallback = $true; remote_patterns = $null }
}

$patchDef = Get-PatchDefinition -Version $claudeVersion

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

$sentinelStr   = "dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX"
$sentinelBytes = [System.Text.Encoding]::ASCII.GetBytes($sentinelStr)

# Fast search: encode bytes as Latin1 string and use .NET's optimized IndexOf
$exeString   = [System.Text.Encoding]::GetEncoding('iso-8859-1').GetString($exeBytes)
$sentinelIdx = $exeString.IndexOf($sentinelStr, [System.StringComparison]::Ordinal)

if ($sentinelIdx -lt 0) { throw "Electron fuse sentinel not found in claude.exe." }

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

if ($patchDef.use_fallback) {
    $patterns = if ($patchDef.remote_patterns) { $patchDef.remote_patterns } else { $FallbackPatterns }
    Write-Host "      Using fallback regex to locate target function..."
    $regexMatch = $null
    foreach ($pattern in $patterns) {
        $regexMatch = [regex]::Match($content, $pattern)
        if ($regexMatch.Success) { break }
    }
    if (-not $regexMatch -or -not $regexMatch.Success) {
        throw "Fallback regex did not match any function in index.js. Manual investigation required."
    }
    $original = $regexMatch.Value
    $funcName = [regex]::Match($original, '^function (\w+)').Groups[1].Value
    $patched  = "function $funcName(e){return true/*patched*/}"
    Write-Host "      Auto-detected function: $funcName"
} else {
    $original = $patchDef.original
    $patched  = $patchDef.patched
}

if ($content.IndexOf($original) -lt 0) {
    if ($content.IndexOf("/*patched*/") -ge 0) {
        Write-Host "      Already patched, skipping."
    } else {
        throw "Patch target not found in index.js. The app may have been updated — check for new patch definitions."
    }
} else {
    $count = ([regex]::Matches($content, [regex]::Escape($original))).Count
    $newContent = $content.Replace($original, $patched)
    [System.IO.File]::WriteAllText($jsPath, $newContent, [System.Text.Encoding]::UTF8)
    Write-Host "      Replaced $count occurrence(s): $($original.Substring(0,40))... -> $patched"
}

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
