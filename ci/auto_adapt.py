"""
auto_adapt.py — Automatically detect new Claude Desktop versions and extract patch targets.

Workflow:
1. Fetch RELEASES manifest from downloads.claude.ai (Windows)
2. Compare latest version against patch-definitions.json
3. If new version found:
   - Windows: download app.asar via range requests (~9MB from nupkg)
   - macOS: resolve DMG URL via redirect, download full DMG, extract with 7z
4. Run matching algorithm on both platforms' index.js
5. Update patch-definitions.json, output results for GitHub Actions

Usage:
  python ci/auto_adapt.py [--dry-run] [--definitions path/to/patch-definitions.json]

Requirements:
  - Python 3.10+ (stdlib only, no third-party deps)
  - 7z in PATH (for macOS DMG extraction, only needed if macOS DMG is available)
"""

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.request
import zlib

RELEASES_URL = "https://downloads.claude.ai/releases/win32/x64/RELEASES"
NUPKG_BASE_URL = "https://downloads.claude.ai/releases/win32/x64/"
MACOS_REDIRECT_URL = "https://api.anthropic.com/api/desktop/darwin/universal/dmg/latest/redirect"

FALLBACK_PATTERNS = [
    # Pattern A: new style with negation prefix (1.7196.0+)
    # function FFA(e){const A=e.toLowerCase();return WXt.test(A)?!1:XJe.test(A)||$Xt.some(t=>A.includes(t))}
    rb'function (\w{2,5})\(e\)\{const (\w)=e\.toLowerCase\(\);return (\w{2,5})\.test\(\2\)\?!1:(\w{2,5})\.test\(\2\)\|\|(\w{2,5})\.some\(t=>\2\.includes\(t\)\)\}',
    # Pattern B: original style (1.6608.x)
    # function bLA(e){const A=e.toLowerCase();return bxe.test(A)||ZWt.some(t=>A.includes(t))}
    rb'function (\w{2,5})\(e\)\{const (\w)=e\.toLowerCase\(\);return (\w{2,5})\.test\(\2\)\|\|(\w{2,5})\.some\(t=>\2\.includes\(t\)\)\}',
]
ANCHOR_ARRAY = b'["claude","sonnet","opus","haiku","anthropic"]'


def fetch_latest_version() -> tuple[str, str]:
    """Fetch RELEASES file and return (version, nupkg_filename) for the latest full package."""
    req = urllib.request.Request(RELEASES_URL, headers={"User-Agent": "Claude-Patch-CI/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        content = resp.read().decode("utf-8-sig")

    full_packages = []
    for line in content.strip().splitlines():
        parts = line.split()
        if len(parts) >= 2 and "-full.nupkg" in parts[1]:
            full_packages.append(parts[1])

    if not full_packages:
        raise RuntimeError("No full packages found in RELEASES")

    latest = full_packages[-1]
    match = re.search(r"AnthropicClaude-([\d.]+)-full\.nupkg", latest)
    if not match:
        raise RuntimeError(f"Cannot parse version from: {latest}")

    return match.group(1), latest


def fetch_macos_dmg_url() -> str | None:
    """Resolve the macOS DMG download URL via redirect."""
    try:
        req = urllib.request.Request(MACOS_REDIRECT_URL, headers={"User-Agent": "Claude-Patch-CI/1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.url
    except Exception as e:
        print(f"  WARNING: Could not resolve macOS DMG URL: {e}")
        return None


def range_request(url: str, start: int, end: int) -> bytes:
    """Download a byte range from a URL."""
    req = urllib.request.Request(url, headers={
        "Range": f"bytes={start}-{end}",
        "User-Agent": "Claude-Patch-CI/1.0",
    })
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


def locate_asar_in_nupkg(url: str) -> tuple[int, int, int]:
    """Find app.asar in nupkg via central directory. Returns (data_offset, compressed_size, compression)."""
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "Claude-Patch-CI/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        file_size = int(resp.headers["Content-Length"])

    tail_size = min(65536, file_size)
    tail = range_request(url, file_size - tail_size, file_size - 1)

    eocd_pos = tail.rfind(b"PK\x05\x06")
    if eocd_pos < 0:
        raise RuntimeError("Cannot find ZIP End of Central Directory")

    cd_size = struct.unpack_from("<I", tail, eocd_pos + 12)[0]
    cd_offset = struct.unpack_from("<I", tail, eocd_pos + 16)[0]

    cd_data = range_request(url, cd_offset, cd_offset + cd_size - 1)

    offset = 0
    while offset < len(cd_data) - 46:
        sig = struct.unpack_from("<I", cd_data, offset)[0]
        if sig != 0x02014B50:
            break
        compression = struct.unpack_from("<H", cd_data, offset + 10)[0]
        compressed_size = struct.unpack_from("<I", cd_data, offset + 20)[0]
        fname_len = struct.unpack_from("<H", cd_data, offset + 28)[0]
        extra_len = struct.unpack_from("<H", cd_data, offset + 30)[0]
        comment_len = struct.unpack_from("<H", cd_data, offset + 32)[0]
        local_header_offset = struct.unpack_from("<I", cd_data, offset + 42)[0]

        fname = cd_data[offset + 46: offset + 46 + fname_len].decode("utf-8", errors="replace")

        if fname.endswith("resources/app.asar"):
            local_header = range_request(url, local_header_offset, local_header_offset + 512)
            lh_fname_len = struct.unpack_from("<H", local_header, 26)[0]
            lh_extra_len = struct.unpack_from("<H", local_header, 28)[0]
            data_offset = local_header_offset + 30 + lh_fname_len + lh_extra_len
            return data_offset, compressed_size, compression

        offset += 46 + fname_len + extra_len + comment_len

    raise RuntimeError("app.asar not found in nupkg")


def download_windows_asar(nupkg_url: str) -> bytes:
    """Download app.asar from Windows nupkg using range requests."""
    print("  Locating app.asar in nupkg...")
    data_offset, compressed_size, compression = locate_asar_in_nupkg(nupkg_url)
    print(f"  Found: offset={data_offset}, size={compressed_size/1024/1024:.1f}MB, compression={compression}")

    print("  Downloading compressed app.asar...")
    compressed_data = range_request(nupkg_url, data_offset, data_offset + compressed_size - 1)

    if compression == 0:
        return compressed_data
    elif compression == 8:
        print("  Decompressing...")
        return zlib.decompress(compressed_data, -15)
    else:
        raise RuntimeError(f"Unsupported compression method: {compression}")


def find_7z() -> str | None:
    """Find 7z executable across platforms."""
    path = shutil.which("7z") or shutil.which("7za")
    if path:
        return path
    # Windows: check common install locations
    for candidate in [
        os.path.join(os.environ.get("ProgramFiles", ""), "7-Zip", "7z.exe"),
        os.path.join(os.environ.get("ProgramFiles(x86)", ""), "7-Zip", "7z.exe"),
    ]:
        if os.path.isfile(candidate):
            return candidate
    return None


def download_macos_asar(dmg_url: str) -> bytes | None:
    """Download macOS DMG and extract app.asar using 7z."""
    sevenz = find_7z()
    if not sevenz:
        print("  WARNING: 7z not found, skipping macOS extraction")
        return None

    tmpdir = tempfile.mkdtemp(prefix="claude_macos_")
    dmg_path = os.path.join(tmpdir, "Claude.dmg")
    asar_path = os.path.join(tmpdir, "app.asar")

    try:
        print(f"  Downloading DMG ({dmg_url.split('/')[-1]})...")
        urllib.request.urlretrieve(dmg_url, dmg_path)
        dmg_size = os.path.getsize(dmg_path)
        print(f"  Downloaded: {dmg_size/1024/1024:.0f} MB")

        print("  Extracting app.asar from DMG...")
        result = subprocess.run(
            [sevenz, "e", dmg_path, "-o" + tmpdir, "Claude/Claude.app/Contents/Resources/app.asar", "-y"],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode != 0:
            print(f"  WARNING: 7z extraction failed: {result.stderr[:200]}")
            return None

        if not os.path.exists(asar_path):
            print("  WARNING: app.asar not found after extraction")
            return None

        with open(asar_path, "rb") as f:
            return f.read()
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def extract_index_js_from_asar(asar_data: bytes) -> bytes:
    """Extract .vite/build/index.js from asar archive bytes."""
    header_total = struct.unpack_from("<I", asar_data, 4)[0]
    header_str_size = struct.unpack_from("<I", asar_data, 12)[0]
    header_json = json.loads(asar_data[16:16 + header_str_size])
    data_start = 8 + header_total

    info = header_json["files"][".vite"]["files"]["build"]["files"]["index.js"]
    js_offset = int(info["offset"])
    js_size = info["size"]
    js_abs = data_start + js_offset

    return asar_data[js_abs:js_abs + js_size]


def extract_function_body(js_content: bytes, start: int) -> bytes | None:
    """Extract a complete function body using brace counting, starting at 'function'."""
    brace_start = js_content.find(b'{', start)
    if brace_start < 0 or brace_start - start > 200:
        return None
    depth = 0
    i = brace_start
    while i < len(js_content) and i < start + 2048:
        if js_content[i:i+1] == b'{':
            depth += 1
        elif js_content[i:i+1] == b'}':
            depth -= 1
            if depth == 0:
                return js_content[start:i+1]
        i += 1
    return None


def find_patch_target(js_content: bytes, platform: str = "") -> dict | None:
    """Find the model validation function in index.js using multi-level matching."""
    prefix = f"  [{platform}] " if platform else "  "

    # Level 1: strict signature match (try each known pattern)
    for pat_idx, pattern in enumerate(FALLBACK_PATTERNS):
        m = re.search(pattern, js_content)
        if m:
            func_name = m.group(1).decode()
            full_match = m.group(0).decode()
            print(f"{prefix}Level 1 match (pattern {pat_idx}): function {func_name}")
            return {"function_name": func_name, "original": full_match}

    # Level 2: anchor-based search with brace-counted body extraction
    print(f"{prefix}Level 1 failed, trying anchor-based search...")
    array_idx = js_content.find(ANCHOR_ARRAY)
    if array_idx < 0:
        print(f"{prefix}ERROR: Anthropic keywords array not found")
        return None

    window_start = max(0, array_idx - 8192)
    window_end = array_idx + 512

    # Find all function(e){ candidates in the window
    candidates = list(re.finditer(rb'function (\w{2,5})\(e\)\{', js_content[window_start:window_end]))
    if not candidates:
        print(f"{prefix}Level 2: No function(e){{ found near anchor")
    else:
        for candidate in reversed(candidates):
            func_name = candidate.group(1).decode()
            func_start = window_start + candidate.start()
            body = extract_function_body(js_content, func_start)
            if not body:
                continue
            if b'.toLowerCase()' not in body:
                continue
            if b'.test(' not in body and b'.includes(' not in body:
                continue
            full_match = body.decode()
            print(f"{prefix}Level 2 match: function {func_name}")
            return {"function_name": func_name, "original": full_match}
        print(f"{prefix}Level 2: No validated function found")

    # Level 3: find variable assigned to anchor array, then find function using that variable
    print(f"{prefix}Trying Level 3: variable reference tracing...")
    # Look for `varName=["claude","sonnet",...]` pattern
    pre_anchor = js_content[max(0, array_idx - 64):array_idx]
    var_match = re.search(rb'(\w{1,5})=\s*$', pre_anchor)
    if not var_match:
        # Try comma-separated: ,varName=
        var_match = re.search(rb'[,;](\w{1,5})=\s*$', pre_anchor)
    if var_match:
        array_var_name = var_match.group(1).decode()
        print(f"{prefix}  Anchor array assigned to variable: {array_var_name}")
        # Search backwards from anchor for functions that reference this variable
        search_start = max(0, array_idx - 16384)
        search_region = js_content[search_start:array_idx]
        # Find functions that use this variable with .some( or .includes( or .test(
        usage_pattern = re.compile(
            rb'function (\w{2,5})\(e\)\{',
        )
        func_candidates = list(usage_pattern.finditer(search_region))
        for candidate in reversed(func_candidates):
            func_start = search_start + candidate.start()
            body = extract_function_body(js_content, func_start)
            if not body:
                continue
            # Must reference the array variable
            if array_var_name.encode() not in body:
                continue
            # Must do some kind of string checking
            if b'.toLowerCase()' not in body and b'.lower' not in body:
                continue
            func_name = candidate.group(1).decode()
            full_match = body.decode()
            print(f"{prefix}Level 3 match: function {func_name} (references {array_var_name})")
            return {"function_name": func_name, "original": full_match}

    # Level 4: broadest search - any function(e) near anchor that does string validation
    print(f"{prefix}Trying Level 4: broad pattern search...")
    search_start = max(0, array_idx - 16384)
    search_region = js_content[search_start:array_idx + 1024]
    for candidate in reversed(list(re.finditer(rb'function (\w{2,5})\(e\)\{', search_region))):
        func_start = search_start + candidate.start()
        body = extract_function_body(js_content, func_start)
        if not body:
            continue
        # Must have at least 2 of these validation signals
        signals = 0
        if b'.toLowerCase()' in body:
            signals += 1
        if b'.test(' in body:
            signals += 1
        if b'.some(' in body:
            signals += 1
        if b'.includes(' in body:
            signals += 1
        if signals >= 2:
            func_name = candidate.group(1).decode()
            full_match = body.decode()
            print(f"{prefix}Level 4 match: function {func_name} (signals={signals})")
            return {"function_name": func_name, "original": full_match}

    print(f"{prefix}ERROR: All matching levels failed")
    return None


def build_patch_entry(win_target: dict, mac_target: dict | None) -> dict:
    """Build a patch-definitions.json entry from matched targets."""
    wf = win_target["function_name"]
    entry = {
        "windows": {
            "original": win_target["original"],
            "patched": f"function {wf}(e){{return true/*patched*/}}",
        },
    }
    if mac_target:
        mf = mac_target["function_name"]
        entry["macos"] = {
            "original": mac_target["original"],
            "patched_prefix": f"function {mf}(e){{return!0}}",
        }
    else:
        print("  WARNING: macOS target not available, using Windows target as fallback")
        print("  WARNING: macOS patch may not work if function names differ between platforms")
        entry["macos"] = {
            "original": win_target["original"],
            "patched_prefix": f"function {wf}(e){{return!0}}",
            "_fallback": True,
        }
    return entry


def set_output(name: str, value: str):
    """Write to GITHUB_OUTPUT if in Actions, otherwise print."""
    gh_output = os.environ.get("GITHUB_OUTPUT")
    if gh_output:
        with open(gh_output, "a") as f:
            f.write(f"{name}={value}\n")
    else:
        print(f"  [output] {name}={value}")


def main():
    parser = argparse.ArgumentParser(description="Auto-detect and adapt to new Claude Desktop versions")
    parser.add_argument("--dry-run", action="store_true", help="Don't write files, just print results")
    parser.add_argument("--definitions", default="patch-definitions.json", help="Path to patch-definitions.json")
    parser.add_argument("--skip-macos", action="store_true", help="Skip macOS DMG download")
    args = parser.parse_args()

    defs_path = args.definitions
    if os.path.exists(defs_path):
        with open(defs_path, "r", encoding="utf-8") as f:
            definitions = json.load(f)
    else:
        definitions = {"schema_version": 1, "definitions": {}}

    # Fetch latest version
    print("[1/5] Checking latest Claude Desktop version...")
    version, nupkg_name = fetch_latest_version()
    print(f"  Latest: {version} ({nupkg_name})")

    if version in definitions.get("definitions", {}):
        print(f"  Version {version} already in definitions. Nothing to do.")
        set_output("status", "up-to-date")
        set_output("version", version)
        return 0

    print(f"  New version detected: {version}")

    # Windows
    print("[2/5] Downloading Windows app.asar from nupkg...")
    nupkg_url = NUPKG_BASE_URL + nupkg_name
    win_asar = download_windows_asar(nupkg_url)
    print(f"  app.asar: {len(win_asar)/1024/1024:.1f} MB")

    print("[3/5] Analyzing Windows index.js...")
    win_js = extract_index_js_from_asar(win_asar)
    print(f"  index.js: {len(win_js)/1024/1024:.1f} MB")
    win_target = find_patch_target(win_js, "win")

    if win_target is None:
        print("  FAILED: Could not find Windows patch target.")
        set_output("status", "failed")
        set_output("version", version)
        return 1

    # macOS
    mac_target = None
    if not args.skip_macos:
        print("[4/5] Downloading macOS app.asar from DMG...")
        dmg_url = fetch_macos_dmg_url()
        if dmg_url:
            mac_asar = download_macos_asar(dmg_url)
            if mac_asar:
                print(f"  app.asar: {len(mac_asar)/1024/1024:.1f} MB")
                mac_js = extract_index_js_from_asar(mac_asar)
                print(f"  index.js: {len(mac_js)/1024/1024:.1f} MB")
                mac_target = find_patch_target(mac_js, "mac")
            else:
                print("  macOS extraction failed, using Windows target as fallback")
        else:
            print("  Could not resolve macOS URL, using Windows target as fallback")
    else:
        print("[4/5] Skipping macOS (--skip-macos)")

    # Build and save
    print("[5/5] Updating patch-definitions.json...")
    entry = build_patch_entry(win_target, mac_target)
    definitions["definitions"][version] = entry

    if args.dry_run:
        print("  [DRY RUN] Would write:")
        print(json.dumps({version: entry}, indent=2))
    else:
        with open(defs_path, "w", encoding="utf-8") as f:
            json.dump(definitions, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print(f"  Written to {defs_path}")

    print()
    print(f"Result: version={version}")
    print(f"  Windows: {win_target['function_name']} -> {win_target['original'][:60]}...")
    if mac_target:
        print(f"  macOS:   {mac_target['function_name']} -> {mac_target['original'][:60]}...")
    set_output("status", "adapted")
    set_output("version", version)
    set_output("function_name", win_target["function_name"])
    return 0


if __name__ == "__main__":
    sys.exit(main())