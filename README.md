# Unclauded(ClaudeDesktop-ModelIDPatch)



A patch allows the Claude client to accept more ModelIDs.

## Supported Versions

- 1.6608.0
- 1.6608.2
- 1.7196.0
- 1.7196.1
- 1.7196.3
- 1.8089.1
- 1.8089.0
- 1.8555.0
- 1.8555.2
- 1.8555.1

The patch scripts auto-detect your installed version and fetch the latest patch definitions from this repository. When a new Claude Desktop version is released, only `patch-definitions.json` needs updating.

## Usage

> Require: Installed Claude Desktop & Enable Developer Mode

### MacOS

```bash
curl -fsSL https://raw.githubusercontent.com/CuzTeam/ClaudeDesktop-ModelIDPatch/refs/heads/main/scripts/patch.sh | bash
```

### Windows PowerShell

```ps1
irm https://raw.githubusercontent.com/CuzTeam/ClaudeDesktop-ModelIDPatch/refs/heads/main/scripts/patch.ps1 | iex
```

## How It Works

1. Disables Electron asar integrity validation (fuse byte flip in `claude.exe`)
2. Patches the model name validation function to always return `true`
3. Fetches patch targets from GitHub at runtime for version compatibility

## Remote Patch

The scripts automatically fetch `patch-definitions.json` from this repo at runtime. This means:

- Users always get the latest patch targets without re-downloading the script
- Adding support for new versions only requires updating the JSON file
- If the remote fetch fails (e.g., no internet), embedded fallback definitions are used
- If the version is unknown, a fallback regex attempts to auto-detect the target function

## Adding Support for New Versions

1. Extract `app.asar` from the new version
2. Search `.vite/build/index.js` for the pattern:
   ```
   function XXX(e){const A=e.toLowerCase();return YYY.test(A)||ZZZ.some(t=>A.includes(t))}
   ```
3. Add the new entry to `patch-definitions.json`
4. Submit a PR

## Reverting

Backups are saved to your Desktop during patching. To revert:

**Windows:**
```ps1
Copy-Item "$env:USERPROFILE\Desktop\claude.exe.bak" "C:\path\to\app\claude.exe" -Force
Copy-Item "$env:USERPROFILE\Desktop\app.asar.bak" "C:\path\to\app\resources\app.asar" -Force
```

**macOS:**
```bash
cp /Applications/Claude.app/Contents/Resources/app.asar.bak /Applications/Claude.app/Contents/Resources/app.asar
```

## CI

![ActPic](https://actpic-gh.vercel.app/api/CuzTeam/ClaudeDesktop-ModelIDPatch/all?theme=dark)

## Thanks
- [Linux.do](https://linux.do): A good technical forum
