"""
auto_adapt.py — Automatically detect new Claude Desktop versions and extract patch targets.

Workflow:
1. Fetch RELEASES manifest from downloads.claude.ai
2. Compare latest version against patch-definitions.json
3. If new version found: download app.asar via range requests (~9MB), extract index.js,
   run matching algorithm, update patch-definitions.json
4. Output results for GitHub Actions to create Issue/PR

Usage:
  python ci/auto_adapt.py [--dry-run] [--definitions path/to/patch-definitions.json]
"""

import argparse
import io
import json
import os
import re
import struct
import sys
import urllib.request
import zlib

RELEASES_URL = "https://downloads.claude.ai/releases/win32/x64/RELEASES"
NUPKG_BASE_URL = "https://downloads.claude.ai/releases/win32/x64/"

FALLBACK_PATTERN = rb'function (\w{2,4})\(e\)\{const (\w)=e\.toLowerCase\(\);return (\w{2,4})\.test\(\2\)\|\|(\w{2,4})\.some\(t=>\2\.includes\(t\)\)\}'
ANCHOR_ARRAY = b'["claude","sonnet","opus","haiku","anthropic"]'
ANCHOR_REGEX = b'/^(sonnet|opus|haiku)(-[\\d.]+)?$/'


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


def range_request(url: str, start: int, end: int) -> bytes:
    """Download a byte range from a URL."""
    req = urllib.request.Request(url, headers={
        "Range": f"bytes={start}-{end}",
        "User-Agent": "Claude-Patch-CI/1.0",
    })
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def locate_asar_in_nupkg(url: str) -> tuple[int, int, int]:
    """Find app.asar in nupkg via central directory. Returns (data_offset, compressed_size, compression)."""
    # Get file size from HEAD
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "Claude-Patch-CI/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        file_size = int(resp.headers["Content-Length"])

    # Download tail to find EOCD
    tail_size = min(65536, file_size)
    tail = range_request(url, file_size - tail_size, file_size - 1)

    eocd_pos = tail.rfind(b"PK\x05\x06")
    if eocd_pos < 0:
        raise RuntimeError("Cannot find ZIP End of Central Directory")

    cd_size = struct.unpack_from("<I", tail, eocd_pos + 12)[0]
    cd_offset = struct.unpack_from("<I", tail, eocd_pos + 16)[0]

    # Download central directory
    cd_data = range_request(url, cd_offset, cd_offset + cd_size - 1)

    # Parse entries to find app.asar
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
            # Read local file header to get actual data start
            local_header = range_request(url, local_header_offset, local_header_offset + 512)
            lh_fname_len = struct.unpack_from("<H", local_header, 26)[0]
            lh_extra_len = struct.unpack_from("<H", local_header, 28)[0]
            data_offset = local_header_offset + 30 + lh_fname_len + lh_extra_len
            return data_offset, compressed_size, compression

        offset += 46 + fname_len + extra_len + comment_len

    raise RuntimeError("app.asar not found in nupkg")


def download_and_extract_asar(url: str) -> bytes:
    """Download app.asar from nupkg using range requests and decompress."""
    print(f"  Locating app.asar in nupkg...")
    data_offset, compressed_size, compression = locate_asar_in_nupkg(url)
    print(f"  Found: offset={data_offset}, size={compressed_size/1024/1024:.1f}MB, compression={compression}")

    print(f"  Downloading compressed app.asar...")
    compressed_data = range_request(url, data_offset, data_offset + compressed_size - 1)

    if compression == 0:
        return compressed_data
    elif compression == 8:
        print(f"  Decompressing...")
        return zlib.decompress(compressed_data, -15)
    else:
        raise RuntimeError(f"Unsupported compression method: {compression}")


def extract_index_js_from_asar(asar_data: bytes) -> bytes:
    """Extract .vite/build/index.js from asar archive bytes."""
    header_size_buf = asar_data[4:8]
    header_total = struct.unpack_from("<I", asar_data, 4)[0]
    header_str_size = struct.unpack_from("<I", asar_data, 12)[0]
    header_json = json.loads(asar_data[16:16 + header_str_size])
    data_start = 8 + header_total

    info = header_json["files"][".vite"]["files"]["build"]["files"]["index.js"]
    js_offset = int(info["offset"])
    js_size = info["size"]
    js_abs = data_start + js_offset

    return asar_data[js_abs:js_abs + js_size]


def find_patch_target(js_content: bytes) -> dict | None:
    """
    Find the model validation function in index.js using multi-level matching.
    Returns dict with 'function_name', 'original', 'regex_var', 'array_var' or None.
    """
    # Level 1: strict signature match
    m = re.search(FALLBACK_PATTERN, js_content)
    if m:
        func_name = m.group(1).decode()
        full_match = m.group(0).decode()
        regex_var = m.group(3).decode()
        array_var = m.group(4).decode()
        print(f"  Level 1 match: function {func_name}, regex={regex_var}, array={array_var}")
        return {
            "function_name": func_name,
            "original": full_match,
            "regex_var": regex_var,
            "array_var": array_var,
        }

    # Level 2: anchor-based search
    print("  Level 1 failed, trying anchor-based search...")
    array_idx = js_content.find(ANCHOR_ARRAY)
    if array_idx < 0:
        print("  ERROR: Anthropic keywords array not found in index.js")
        return None

    # Search backwards from array for the enclosing function
    window_start = max(0, array_idx - 2048)
    window = js_content[window_start:array_idx + 256]

    # Find the last "function XXX(e){" before the array
    candidates = list(re.finditer(rb'function (\w{2,5})\(e\)\{', window))
    if not candidates:
        print("  ERROR: No function(e){ found near anchor")
        return None

    # Take the closest one before the array position
    best = candidates[-1]
    func_name = best.group(1).decode()

    # Try to extract the full function body (up to next function or reasonable boundary)
    func_start = window_start + best.start()
    # Search for the function's closing pattern
    slice_after = js_content[func_start:func_start + 512]
    # Match the full function: function XXX(e){...}
    body_match = re.match(rb'function \w+\(e\)\{[^}]+\}', slice_after)
    if body_match:
        full_match = body_match.group(0).decode()
        print(f"  Level 2 match: function {func_name}")
        print(f"  Full match: {full_match[:80]}...")
        return {
            "function_name": func_name,
            "original": full_match,
            "regex_var": "unknown",
            "array_var": "unknown",
        }

    print(f"  ERROR: Could not extract function body for {func_name}")
    return None


def build_patch_entry(target: dict) -> dict:
    """Build a patch-definitions.json entry from a matched target."""
    func_name = target["function_name"]
    original = target["original"]
    return {
        "windows": {
            "original": original,
            "patched": f"function {func_name}(e){{return true/*patched*/}}",
        },
        "macos": {
            "original": original,
            "patched_prefix": f"function {func_name}(e){{return!0}}",
        },
    }


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
    args = parser.parse_args()

    # Load current definitions
    defs_path = args.definitions
    if os.path.exists(defs_path):
        with open(defs_path, "r", encoding="utf-8") as f:
            definitions = json.load(f)
    else:
        definitions = {"schema_version": 1, "definitions": {}}

    # Fetch latest version
    print("[1/4] Checking latest Claude Desktop version...")
    version, nupkg_name = fetch_latest_version()
    print(f"  Latest: {version} ({nupkg_name})")

    # Check if already adapted
    if version in definitions.get("definitions", {}):
        print(f"  Version {version} already in definitions. Nothing to do.")
        set_output("status", "up-to-date")
        set_output("version", version)
        return 0

    print(f"  New version detected: {version}")

    # Download and extract
    print("[2/4] Downloading app.asar from nupkg...")
    nupkg_url = NUPKG_BASE_URL + nupkg_name
    asar_data = download_and_extract_asar(nupkg_url)
    print(f"  app.asar: {len(asar_data)/1024/1024:.1f} MB")

    print("[3/4] Extracting and analyzing index.js...")
    index_js = extract_index_js_from_asar(asar_data)
    print(f"  index.js: {len(index_js)/1024/1024:.1f} MB")

    target = find_patch_target(index_js)
    if target is None:
        print("  FAILED: Could not find patch target.")
        set_output("status", "failed")
        set_output("version", version)
        return 1

    # Build and save
    print("[4/4] Updating patch-definitions.json...")
    entry = build_patch_entry(target)
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
    print(f"Result: version={version}, function={target['function_name']}")
    print(f"  original: {target['original'][:80]}...")
    set_output("status", "adapted")
    set_output("version", version)
    set_output("function_name", target["function_name"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
