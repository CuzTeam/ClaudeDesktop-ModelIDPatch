#!/usr/bin/env bash
# patch.sh — Claude Desktop custom-model patch (macOS)
#
# Patches two things:
#   1. Model name validation function in app.asar → always return true
#      (allows non-default model names in inferenceModels)
#   2. Electron fuse EnableEmbeddedAsarIntegrityValidation → OFF
#      (allows the modified asar to load without hash mismatch)
#
# Usage:
#   ./patch.sh [--claude-dir /path/to/Claude.app]
#
# Default Claude.app location: /Applications/Claude.app
#
# Output:
#   ./claude-dmg/Claude-patched-<version>.dmg  (or .zip if hdiutil unavailable)
#
set -euo pipefail

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[patch] $*"; }

# ── args ─────────────────────────────────────────────────────────────────────
CLAUDE_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude-dir) CLAUDE_DIR="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$CLAUDE_DIR" ]] && CLAUDE_DIR="/Applications/Claude.app"
[[ -d "$CLAUDE_DIR" ]] || die "Claude.app not found at: $CLAUDE_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DMG_OUT="$SCRIPT_DIR/claude-dmg"
mkdir -p "$DMG_OUT"

# ── version ──────────────────────────────────────────────────────────────────
APP_VERSION=$(defaults read "$CLAUDE_DIR/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")
info "Claude version: $APP_VERSION"

# ── backup ───────────────────────────────────────────────────────────────────
BACKUP_DIR="$SCRIPT_DIR/claude-backup-$APP_VERSION"
if [[ -d "$BACKUP_DIR" ]]; then
  info "Backup already exists at $BACKUP_DIR, skipping"
else
  info "Backing up to $BACKUP_DIR ..."
  cp -a "$CLAUDE_DIR" "$BACKUP_DIR"
  info "Backup done"
fi

# ── work copy ────────────────────────────────────────────────────────────────
WORK_APP="$SCRIPT_DIR/Claude-work.app"
info "Creating work copy ..."
rm -rf "$WORK_APP"
cp -a "$CLAUDE_DIR" "$WORK_APP"

ASAR_PATH="$WORK_APP/Contents/Resources/app.asar"
ELECTRON_FW="$WORK_APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"

# ── Python patcher ───────────────────────────────────────────────────────────
info "Running patcher ..."
ASAR_PATH="$ASAR_PATH" ELECTRON_FW="$ELECTRON_FW" python3 << 'PYEOF'
import json, struct, hashlib, copy, sys, os

ASAR_PATH   = os.environ["ASAR_PATH"]
ELECTRON_FW = os.environ["ELECTRON_FW"]

# ── ASAR helpers ─────────────────────────────────────────────────────────────

def parse_asar(path):
    # Layout: [4: b0][4: b1][4: json_sz][json_sz bytes: [4: str_len][JSON][padding]]
    # data_off = 12 + json_sz  (str_len is INSIDE the json_sz region)
    with open(path, "rb") as f:
        f.read(4)                                        # b0: outer pickle payload size
        f.read(4)                                        # b1: inner pickle payload size
        json_size = struct.unpack("<I", f.read(4))[0]   # json_sz: padded header region size
        inner     = f.read(json_size)                   # [4: str_len][JSON bytes][padding]
        data_off  = f.tell()                             # = 12 + json_sz
    str_len = struct.unpack("<I", inner[0:4])[0]
    header  = json.loads(inner[4:4+str_len])
    return header, data_off

def get_node(header, vpath):
    node = header
    for part in (p for p in vpath.split("/") if p):
        node = node.get("files", {}).get(part)
        if node is None:
            return None
    return node

def read_entry(path, header, data_off, vpath):
    node = get_node(header, vpath)
    if node is None or "offset" not in node:
        return None
    with open(path, "rb") as f:
        f.seek(data_off + int(node["offset"]))
        return f.read(int(node["size"]))

def sha256(data):
    return hashlib.sha256(data).hexdigest()

def sha256_blocks(data, block_size=4194304):
    return [sha256(data[i:i+block_size]) for i in range(0, len(data), block_size)]

def collect_files(header):
    """Return list of (vpath, node) sorted by original offset."""
    result = []
    def walk(node, vpath=""):
        if "files" in node:
            for k, v in node["files"].items():
                walk(v, f"{vpath}/{k}")
        elif "offset" in node:
            result.append((vpath, node))
    walk(header)
    result.sort(key=lambda x: int(x[1]["offset"]))
    return result

def rebuild_asar(orig_path, header, data_off, patches):
    """
    patches: {vpath: new_bytes}
    Reads all files from orig_path, applies patches, rebuilds the asar
    with updated offsets and integrity hashes.
    """
    all_files = collect_files(header)

    # Read all file data
    file_data = {}
    with open(orig_path, "rb") as f:
        for vpath, node in all_files:
            if vpath in patches:
                file_data[vpath] = patches[vpath]
            else:
                f.seek(data_off + int(node["offset"]))
                file_data[vpath] = f.read(int(node["size"]))

    # Rebuild header with updated offsets + integrity hashes
    new_header = copy.deepcopy(header)
    new_offset = 0

    def update(node, vpath=""):
        nonlocal new_offset
        if "files" in node:
            for k, v in node["files"].items():
                update(v, f"{vpath}/{k}")
        elif "offset" in node:
            data = file_data[vpath]
            node["offset"] = str(new_offset)
            node["size"]   = len(data)
            if "integrity" in node:
                blk = node["integrity"]["blockSize"]
                node["integrity"]["hash"]   = sha256(data)
                node["integrity"]["blocks"] = sha256_blocks(data, blk)
            new_offset += len(data)

    update(new_header)

    # Serialise header (Chromium pickle format)
    # Layout: [4: b0=4][4: b1=json_sz+4][4: json_sz][json_sz bytes: [4: str_len][JSON][padding]]
    # json_sz = ceil((str_len + 4 + 1) / 8) * 8  — 8-byte aligned (str_len field + JSON + null)
    hdr_json = json.dumps(new_header, separators=(",", ":")).encode()
    str_len  = len(hdr_json)
    # json_sz covers: [4: str_len field] + [str_len: JSON] + [1: null] + [padding]
    # Must be 8-byte aligned
    json_sz  = ((4 + str_len + 1) + 7) // 8 * 8
    b1       = json_sz + 4                      # b1 = json_sz + 4 (the json_sz uint32 field)

    header_bytes = (
        struct.pack("<I", 4)       +   # b0: outer pickle payload size (constant 4)
        struct.pack("<I", b1)      +   # b1: inner pickle payload size = json_sz + 4
        struct.pack("<I", json_sz) +   # json_sz: padded header region size
        struct.pack("<I", str_len) +   # str_len: JSON string length (first 4 bytes of json_sz region)
        hdr_json                   +   # JSON bytes
        b"\x00"                    +   # null terminator
        b"\x00" * (json_sz - 4 - str_len - 1)  # alignment padding
    )

    body = b"".join(file_data[vpath] for vpath, _ in all_files)
    return header_bytes + body

# ── Patch 1: model name validation stub ──────────────────────────────────────
# The validation function checks whether a model name contains known keywords.
# We replace the entire function body with `return!0` (always true),
# padded to the exact same byte length so all other offsets stay valid.
#
# Original (87 bytes):
#   function LbA(e){const A=e.toLowerCase();return Lxe.test(A)||Z$t.some(t=>A.includes(t))}
# Patched:
#   function LbA(e){return!0}   + spaces to fill 87 bytes

OLD_LBA = b"function LbA(e){const A=e.toLowerCase();return Lxe.test(A)||Z$t.some(t=>A.includes(t))}"
_stub   = b"function LbA(e){return!0}"
NEW_LBA = _stub + b" " * (len(OLD_LBA) - len(_stub))
assert len(OLD_LBA) == len(NEW_LBA), f"LbA length mismatch: {len(OLD_LBA)} vs {len(NEW_LBA)}"

print("[patch] Parsing ASAR ...")
header, data_off = parse_asar(ASAR_PATH)

print("[patch] Reading index.js ...")
index_js = read_entry(ASAR_PATH, header, data_off, "/.vite/build/index.js")
if index_js is None:
    sys.exit("ERROR: index.js not found in asar")

if OLD_LBA not in index_js:
    sys.exit("ERROR: model validation pattern not found — app version may have changed")

patched_index = index_js.replace(OLD_LBA, NEW_LBA, 1)
assert patched_index != index_js, "patch had no effect"
print(f"[patch] model validation stubbed out ({len(OLD_LBA)} bytes, same length)")

# ── Patch 2: rebuild ASAR with updated hashes ────────────────────────────────
print("[patch] Rebuilding ASAR with updated integrity hashes ...")
new_asar = rebuild_asar(
    ASAR_PATH, header, data_off,
    {"/.vite/build/index.js": patched_index}
)
with open(ASAR_PATH, "wb") as f:
    f.write(new_asar)
print(f"[patch] ASAR written ({len(new_asar):,} bytes)")

# ── Patch 3: update ElectronAsarIntegrity hash in Info.plist ─────────────────
# Electron hashes only the JSON header string (not the full asar file).
# The hash is stored in Info.plist under ElectronAsarIntegrity:Resources/app.asar:hash
import subprocess

# Extract the JSON header bytes from the rebuilt asar
new_json_sz  = struct.unpack("<I", new_asar[8:12])[0]
new_str_len  = struct.unpack("<I", new_asar[12:16])[0]
new_json_str = new_asar[16:16+new_str_len]
new_json_hash = sha256(new_json_str)

info_plist = os.path.join(os.path.dirname(os.path.dirname(ASAR_PATH)), "Info.plist")
print(f"[patch] Updating ElectronAsarIntegrity hash in Info.plist ...")
print(f"[patch]   new hash: {new_json_hash}")

r = subprocess.run(
    ["/usr/libexec/PlistBuddy", "-c",
     f"Set :ElectronAsarIntegrity:Resources/app.asar:hash {new_json_hash}", info_plist],
    capture_output=True, text=True
)
if r.returncode != 0:
    sys.exit(f"ERROR: PlistBuddy failed: {r.stderr}")
print("[patch] Info.plist updated")

# ── Patch 4: disable EnableEmbeddedAsarIntegrityValidation fuse ──────────────
# Fuse wire layout (this Electron build):
#   sentinel (32 bytes) | version (1) | count (1) | fuse[0..N] (ASCII '0'/'1')
# Fuse index 4 = EnableEmbeddedAsarIntegrityValidation
FUSE_SENTINEL = b"dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX"
FUSE_ASAR_IDX = 4

print("[patch] Patching Electron fuse ...")
with open(ELECTRON_FW, "rb") as f:
    fw = bytearray(f.read())

idx = fw.find(FUSE_SENTINEL)
if idx < 0:
    sys.exit("ERROR: Electron fuse sentinel not found — binary may have changed")

fuse_base = idx + len(FUSE_SENTINEL) + 2   # skip version + count bytes
count     = fw[idx + len(FUSE_SENTINEL) + 1]

before = "".join(chr(fw[fuse_base + i]) for i in range(count))
fw[fuse_base + FUSE_ASAR_IDX] = ord("0")
after  = "".join(chr(fw[fuse_base + i]) for i in range(count))

print(f"[patch]   fuses before: {before}")
print(f"[patch]   fuses after:  {after}")

with open(ELECTRON_FW, "wb") as f:
    f.write(fw)
print("[patch] Electron fuse patched")
PYEOF

# ── Re-sign (ad-hoc) ──────────────────────────────────────────────────────────
info "Re-signing app bundle (ad-hoc) ..."

# Sign Electron Framework first (we modified it)
codesign --force --deep --sign - \
  "$WORK_APP/Contents/Frameworks/Electron Framework.framework" \
  2>&1 | grep -v "replacing existing signature" || true

# Sign helper apps
for helper in \
  "$WORK_APP/Contents/Frameworks/Claude Helper.app" \
  "$WORK_APP/Contents/Frameworks/Claude Helper (GPU).app" \
  "$WORK_APP/Contents/Frameworks/Claude Helper (Plugin).app" \
  "$WORK_APP/Contents/Frameworks/Claude Helper (Renderer).app"
do
  [[ -d "$helper" ]] && codesign --force --deep --sign - "$helper" \
    2>&1 | grep -v "replacing existing signature" || true
done

# Sign the main bundle
codesign --force --deep --sign - "$WORK_APP" \
  2>&1 | grep -v "replacing existing signature" || true

info "Signing done"

# ── Package DMG ───────────────────────────────────────────────────────────────
DMG_PATH="$DMG_OUT/Claude-patched-${APP_VERSION}.dmg"
info "Creating DMG at $DMG_PATH ..."

STAGE_DIR="$SCRIPT_DIR/claude-stage-$$"
mkdir -p "$STAGE_DIR"
trap 'rm -rf "$STAGE_DIR" "$WORK_APP"' EXIT

cp -a "$WORK_APP" "$STAGE_DIR/Claude.app"

if hdiutil create \
     -volname "Claude Patched $APP_VERSION" \
     -srcfolder "$STAGE_DIR" \
     -ov \
     -format UDZO \
     -imagekey zlib-level=6 \
     "$DMG_PATH" > /dev/null 2>&1; then
  info "DMG created: $DMG_PATH"
else
  # Fallback: zip archive (drag-install not supported, but preserves the bundle)
  ZIP_PATH="$DMG_OUT/Claude-patched-${APP_VERSION}.zip"
  info "hdiutil unavailable, falling back to zip: $ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$STAGE_DIR/Claude.app" "$ZIP_PATH"
  info "Zip created: $ZIP_PATH"
fi
