#!/usr/bin/env bash
set -euo pipefail

APP="${1:-/Applications/Claude.app}"
ASAR="$APP/Contents/Resources/app.asar"
ASAR_BAK="$APP/Contents/Resources/app.asar.bak"

REMOTE_URL="https://raw.githubusercontent.com/CuzTeam/ClaudeDesktop-ModelIDPatch/refs/heads/main/patch-definitions.json"

[ -d "$APP"  ] || { echo "error: $APP not found" >&2; exit 1; }
[ -f "$ASAR" ] || { echo "error: $ASAR not found" >&2; exit 1; }

# --- detect version ----------------------------------------------------------
CLAUDE_VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
echo "Detected Claude Desktop version: $CLAUDE_VERSION"

# --- fetch remote patch definitions ------------------------------------------
echo "Fetching patch definitions from remote..."
PATCH_JSON=$(curl -fsSL --connect-timeout 10 "$REMOTE_URL" 2>/dev/null || echo "")
if [ -n "$PATCH_JSON" ]; then
  echo "  Remote fetch OK."
else
  echo "  Remote fetch failed, will use embedded definitions."
fi

# --- backup ------------------------------------------------------------------
if [ -f "$ASAR_BAK" ]; then
  echo "backup exists: $ASAR_BAK (skipping)"
else
  cp "$ASAR" "$ASAR_BAK"
  echo "backed up: $ASAR_BAK"
fi

# --- patch asar in-place -----------------------------------------------------
PATCH_JSON="$PATCH_JSON" CLAUDE_VERSION="$CLAUDE_VERSION" python3 - "$ASAR" << 'PYTHON'
import sys, struct, json, hashlib, os, re, plistlib

path = sys.argv[1]
patch_json_str = os.environ.get('PATCH_JSON', '')
claude_version = os.environ.get('CLAUDE_VERSION', 'unknown')

# Embedded fallback definitions
EMBEDDED = {
    "1.6608.0": {
        "original": b'function LbA(e){const A=e.toLowerCase();return Lxe.test(A)||Z$t.some(t=>A.includes(t))}',
        "patched_prefix": b'function LbA(e){return!0}'
    },
    "1.6608.2": {
        "original": b'function OLA(e){const A=e.toLowerCase();return Yxe.test(A)||tZt.some(t=>A.includes(t))}',
        "patched_prefix": b'function OLA(e){return!0}'
    }
}
FALLBACK_PATTERNS = [
    rb'function \w{2,5}\(e\)\{const A=e\.toLowerCase\(\);return \w{2,5}\.test\(A\)\?!1:\w{2,5}\.test\(A\)\|\|\w{2,5}\.some\(t=>A\.includes\(t\)\)\}',
    rb'function \w{2,5}\(e\)\{const A=e\.toLowerCase\(\);return \w{2,5}\.test\(A\)\|\|\w{2,5}\.some\(t=>A\.includes\(t\)\)\}',
]

OLD = None
NEW = None

# Try remote definition first
if patch_json_str:
    try:
        defs = json.loads(patch_json_str)
        ver_def = defs.get('definitions', {}).get(claude_version, {}).get('macos', {})
        if ver_def:
            OLD = ver_def['original'].encode()
            prefix = ver_def['patched_prefix'].encode()
            NEW = prefix + b' ' * (len(OLD) - len(prefix))
            print("Using remote definition for version %s" % claude_version)
        # Load remote fallback patterns if available
        remote_patterns = defs.get('fallback_patterns') or (
            [defs['fallback_pattern']] if defs.get('fallback_pattern') else None
        )
        if remote_patterns:
            FALLBACK_PATTERNS = [p.encode() if isinstance(p, str) else p for p in remote_patterns]
    except Exception as e:
        print("Remote JSON parse error: %s" % e)

# Fall back to embedded
if OLD is None and claude_version in EMBEDDED:
    OLD = EMBEDDED[claude_version]['original']
    prefix = EMBEDDED[claude_version]['patched_prefix']
    NEW = prefix + b' ' * (len(OLD) - len(prefix))
    print("Using embedded definition for version %s" % claude_version)

with open(path, 'rb') as f:
    raw = bytearray(f.read())

b0, b1, b2, b3 = struct.unpack_from('<IIII', raw, 0)
header = json.loads(raw[16:16 + b3])
data_start = 8 + b1

info      = header['files']['.vite']['files']['build']['files']['index.js']
js_offset = int(info['offset'])
js_size   = info['size']
js_abs    = data_start + js_offset
js_bytes  = raw[js_abs : js_abs + js_size]

# If no definition matched, try fallback regex
if OLD is None:
    print("No definition for version %s, trying fallback regex..." % claude_version)
    m = None
    for pat in FALLBACK_PATTERNS:
        m = re.search(pat, js_bytes)
        if m:
            break
    if not m:
        print("error: fallback regex did not match -- manual investigation required")
        sys.exit(1)
    OLD = m.group(0)
    func_name = re.match(rb'function (\w+)', OLD).group(1)
    prefix = b'function ' + func_name + b'(e){return!0}'
    NEW = prefix + b' ' * (len(OLD) - len(prefix))
    print("Auto-detected function: %s" % func_name.decode())

assert len(NEW) == len(OLD), "Patch length mismatch: %d vs %d" % (len(NEW), len(OLD))

count = js_bytes.count(OLD)
if count == 0:
    if b'return!0}' in js_bytes and b'/*patched*/' in js_bytes or b'return!0} ' in js_bytes:
        print("Already patched, skipping.")
        sys.exit(0)
    print("error: target not found -- version mismatch or unknown change")
    sys.exit(1)
if count > 1:
    print("error: %d matches, expected 1" % count)
    sys.exit(1)

idx = js_bytes.find(OLD)
patch_offset = js_abs + idx
raw[patch_offset : patch_offset + len(OLD)] = NEW
print("patched at offset %d" % patch_offset)

patched_js = bytes(raw[js_abs : js_abs + js_size])
BLOCK = info['integrity']['blockSize']
info['integrity']['hash'] = hashlib.sha256(patched_js).hexdigest()
info['integrity']['blocks'] = [
    hashlib.sha256(patched_js[i:i+BLOCK]).hexdigest()
    for i in range(0, js_size, BLOCK)
]

new_header_str = json.dumps(header, separators=(',', ':')).encode('utf-8')
header_space = data_start - 16
if len(new_header_str) > header_space:
    print("error: header too large (%d > %d)" % (len(new_header_str), header_space))
    sys.exit(1)

padded_header = new_header_str + b'\x00' * (header_space - len(new_header_str))
struct.pack_into('<I', raw, 12, len(new_header_str))
raw[16:data_start] = padded_header

with open(path, 'wb') as f:
    f.write(raw)
print("asar patched: %d bytes" % len(raw))

header_hash = hashlib.sha256(new_header_str).hexdigest()
app_dir = os.path.dirname(os.path.dirname(os.path.dirname(path)))
plist_path = os.path.join(app_dir, 'Contents', 'Info.plist')
if os.path.exists(plist_path):
    with open(plist_path, 'rb') as f:
        plist = plistlib.load(f)
    if 'ElectronAsarIntegrity' in plist:
        key = 'Resources/app.asar'
        if key in plist['ElectronAsarIntegrity']:
            old_hash = plist['ElectronAsarIntegrity'][key]['hash']
            plist['ElectronAsarIntegrity'][key]['hash'] = header_hash
            with open(plist_path, 'wb') as f:
                plistlib.dump(plist, f)
            print("Info.plist: %s -> %s" % (old_hash[:16], header_hash[:16]))
PYTHON

# --- entitlements (generated inline) -----------------------------------------
ENT_MAIN=$(mktemp)
cat > "$ENT_MAIN" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.device.bluetooth</key>
	<true/>
	<key>com.apple.security.device.camera</key>
	<true/>
	<key>com.apple.security.device.print</key>
	<true/>
	<key>com.apple.security.device.usb</key>
	<true/>
	<key>com.apple.security.personal-information.location</key>
	<true/>
	<key>com.apple.security.personal-information.photos-library</key>
	<true/>
	<key>com.apple.security.virtualization</key>
	<true/>
</dict>
</plist>
EOF

ENT_JIT=$(mktemp)
cat > "$ENT_JIT" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
</dict>
</plist>
EOF

ENT_PLUGIN=$(mktemp)
cat > "$ENT_PLUGIN" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
	<true/>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
</plist>
EOF

# --- re-sign (ad-hoc, inside-out, preserving entitlements) ---
echo "re-signing..."
find "$APP" -name "*.dylib" -exec /usr/bin/codesign --force --sign - {} \; 2>/dev/null
find "$APP/Contents/Helpers" -type f -perm +111 -exec /usr/bin/codesign --force --sign - {} \; 2>/dev/null
find "$APP/Contents/Frameworks" -path "*/Helpers/*" -type f -perm +111 -exec /usr/bin/codesign --force --sign - {} \; 2>/dev/null
for fw in "Electron Framework" "Mantle" "ReactiveObjC" "Squirrel"; do
  /usr/bin/codesign --force --sign - "$APP/Contents/Frameworks/${fw}.framework" 2>/dev/null
done
/usr/bin/codesign --force --sign - --entitlements "$ENT_MAIN" "$APP/Contents/Frameworks/Claude Helper.app" 2>/dev/null
/usr/bin/codesign --force --sign - --entitlements "$ENT_JIT" "$APP/Contents/Frameworks/Claude Helper (GPU).app" 2>/dev/null
/usr/bin/codesign --force --sign - --entitlements "$ENT_PLUGIN" "$APP/Contents/Frameworks/Claude Helper (Plugin).app" 2>/dev/null
/usr/bin/codesign --force --sign - --entitlements "$ENT_JIT" "$APP/Contents/Frameworks/Claude Helper (Renderer).app" 2>/dev/null
/usr/bin/codesign --force --sign - --entitlements "$ENT_MAIN" "$APP"

rm -f "$ENT_MAIN" "$ENT_JIT" "$ENT_PLUGIN"

if /usr/bin/codesign -v --deep "$APP" 2>/dev/null; then
  echo "codesign OK."
else
  echo "error: codesign verification failed" >&2
  /usr/bin/codesign -v --deep "$APP" 2>&1
  exit 1
fi

# --- clear quarantine ---
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "done."
