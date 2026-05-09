#!/usr/bin/env bash
set -euo pipefail

APP="${1:-/Applications/Claude.app}"
ASAR="$APP/Contents/Resources/app.asar"
ASAR_BAK="$APP/Contents/Resources/app.asar.bak"

[ -d "$APP"  ] || { echo "error: $APP not found" >&2; exit 1; }
[ -f "$ASAR" ] || { echo "error: $ASAR not found" >&2; exit 1; }

if [ -f "$ASAR_BAK" ]; then
  echo "backup exists: $ASAR_BAK (skipping)"
else
  cp "$ASAR" "$ASAR_BAK"
  echo "backed up: $ASAR_BAK"
fi

# --- patch asar in-place -----------------------------------------------------
python3 - "$ASAR" << 'PYTHON'
import sys, struct, json, hashlib, os, plistlib

path = sys.argv[1]

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

OLD = b'function LbA(e){const A=e.toLowerCase();return Lxe.test(A)||Z$t.some(t=>A.includes(t))}'
NEW = b'function LbA(e){return!0}' + b' ' * (len(OLD) - len(b'function LbA(e){return!0}'))
assert len(NEW) == len(OLD)

count = js_bytes.count(OLD)
if count == 0:
    print("error: target not found -- already patched or version mismatch")
    sys.exit(1)
if count > 1:
    print("error: %d matches, expected 1" % count)
    sys.exit(1)

idx = js_bytes.find(OLD)
patch_offset = js_abs + idx
raw[patch_offset : patch_offset + len(OLD)] = NEW
print("patched LbA() at offset %d" % patch_offset)

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
