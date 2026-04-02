# MDV Build & Release Guide

Step-by-step process to build, sign, package, and release MDV with working Sparkle auto-updates.

---

## Prerequisites

- Xcode 16+ with Apple Development certificate (Team ID: `C5VZ9848T6`)
- GitHub CLI (`gh`) authenticated
- Sparkle EdDSA private key in Keychain (stored by `sign_update` tool on first run)

---

## 1. Update Version Numbers

In `MDV.xcodeproj/project.pbxproj`, update **all four** build configurations (MDV Debug, MDV Release, MDVQuickLook Debug, MDVQuickLook Release):

```
MARKETING_VERSION = X.Y;        # User-facing version (e.g. 1.2)
CURRENT_PROJECT_VERSION = N;     # Sparkle build number, must increment (e.g. 3)
```

Sparkle uses `CURRENT_PROJECT_VERSION` (maps to `sparkle:version`) to determine if an update is available. **It must be higher than the previous release.**

---

## 2. Build for Release

```bash
cd /Users/jaylee/Documents/work/mdv/MDV

xcodebuild -project MDV.xcodeproj \
  -scheme MDV \
  -configuration Release \
  -derivedDataPath build \
  clean build \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
```

### Why these flags matter

| Flag | Purpose |
|------|---------|
| `-configuration Release` | Optimized build without debug symbols |
| `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` | Strips `get-task-allow` debug entitlement that prevents the app from running outside Xcode |

### Do NOT use `CODE_SIGN_IDENTITY="-"`

Ad-hoc signing breaks two things:
- **Sparkle framework loading** — dyld refuses to load Sparkle.framework because the Team ID of the ad-hoc app (none) doesn't match the Team ID of the framework. Crash on launch: `Library not loaded: Sparkle.framework`
- **QuickLook extension** — macOS `pluginkit` won't register ad-hoc signed app extensions. The QuickLook preview will silently not work.

The build must use the default Apple Development certificate so that the app, Sparkle.framework, and MDVQuickLook.appex all share the same Team ID.

### Sandbox Configuration

The main app (MDV) must have **`ENABLE_APP_SANDBOX = NO`**. The QuickLook extension (MDVQuickLook) must have **`ENABLE_APP_SANDBOX = YES`**.

- **Main app unsandboxed** — Sparkle's `Installer.xpc` inside the framework is ad-hoc signed with no Team ID. In a sandboxed app, macOS blocks the XPC service launch due to the signing mismatch, causing "An error occurred while launching the installer" on every update attempt. Removing the sandbox from the main app lets Sparkle's updater work without needing a $99 Developer ID certificate.
- **QuickLook extension sandboxed** — macOS requires all app extensions to be sandboxed. Without it, the extension won't be registered and QuickLook previews silently fail.

---

## 3. Verify Code Signing

Run these checks before packaging:

```bash
APP="build/Build/Products/Release/MDV.app"

# All three must show the same Authority and no "adhoc" in flags
codesign -dvvv "$APP" 2>&1 | grep -E "Authority|flags"
codesign -dvvv "$APP/Contents/Frameworks/Sparkle.framework" 2>&1 | grep -E "Authority|flags"
codesign -dvvv "$APP/Contents/PlugIns/MDVQuickLook.appex" 2>&1 | grep -E "Authority|flags"

# Deep verification — must print nothing (no errors)
codesign --verify --deep --strict "$APP"
```

Expected output for each:
```
CodeDirectory ... flags=0x10000(runtime) ...
Authority=Apple Development: jaeyounglee9030@gmail.com (QMYZN65P6L)
```

If any component shows `flags=0x2(adhoc)` or a different Authority, the build is broken.

---

## 4. Create DMG with Applications Shortcut

```bash
mkdir -p /tmp/mdv-dmg
cp -R build/Build/Products/Release/MDV.app /tmp/mdv-dmg/
ln -sf /Applications /tmp/mdv-dmg/Applications

hdiutil create -volname "MDV" \
  -srcfolder /tmp/mdv-dmg \
  -ov -format UDZO \
  build/MDV-X.Y.dmg

rm -rf /tmp/mdv-dmg
```

The `Applications` symlink lets users drag-to-install from the DMG window.

---

## 5. Sign DMG with Sparkle EdDSA

```bash
SIGN_TOOL="build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
$SIGN_TOOL build/MDV-X.Y.dmg
```

Output:
```
sparkle:edSignature="..." length="..."
```

Copy both values — you need them for the appcast.

The EdDSA private key is stored in your Keychain. The corresponding public key is in `MDV/Info.plist` under `SUPublicEDKey`. These must match or Sparkle will reject the update.

---

## 6. Update appcast.xml

Add a new `<item>` block at the top of the `<channel>` (before existing items):

```xml
<item>
    <title>Version X.Y</title>
    <sparkle:version>N</sparkle:version>
    <sparkle:shortVersionString>X.Y</sparkle:shortVersionString>
    <pubDate>Day, DD Mon YYYY HH:MM:SS +0000</pubDate>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <description><![CDATA[
        <h2>MDV X.Y</h2>
        <ul>
            <li>Change 1</li>
            <li>Change 2</li>
        </ul>
    ]]></description>
    <enclosure url="https://github.com/jayl930/MDV/releases/download/vX.Y/MDV-X.Y.dmg"
               type="application/octet-stream"
               sparkle:edSignature="PASTE_SIGNATURE_HERE"
               length="PASTE_LENGTH_HERE"/>
</item>
```

### Fields

| Field | Value | Notes |
|-------|-------|-------|
| `sparkle:version` | `N` | Must match `CURRENT_PROJECT_VERSION` and be higher than previous |
| `sparkle:shortVersionString` | `X.Y` | Must match `MARKETING_VERSION` |
| `sparkle:edSignature` | From step 5 | EdDSA signature of the DMG |
| `length` | From step 5 | File size in bytes |

Keep previous `<item>` entries — Sparkle uses them for delta comparisons.

---

## 7. Commit, Tag, Push

```bash
git add -A
git commit -m "Release vX.Y"
git tag vX.Y
git push origin main
git push origin vX.Y
```

---

## 8. Create GitHub Release and Upload DMG

```bash
gh release create vX.Y \
  --title "vX.Y" \
  --notes "Release notes here" \
  --repo jayl930/MDV

gh release upload vX.Y build/MDV-X.Y.dmg --repo jayl930/MDV
```

The DMG URL in appcast.xml points to this release asset. If the filename or tag doesn't match, Sparkle will 404.

---

## Sparkle Architecture Reference

```
MDV/Info.plist
  └── SUPublicEDKey        → EdDSA public key (verifies signatures)
  └── SUFeedURL            → Points to raw appcast.xml on GitHub main branch

appcast.xml
  └── sparkle:edSignature  → EdDSA signature of the DMG (from sign_update)
  └── sparkle:version      → Build number (compared to running app's CFBundleVersion)

Keychain
  └── EdDSA private key    → Used by sign_update tool to generate signatures
```

### How Sparkle checks for updates

1. Fetches `appcast.xml` from `SUFeedURL`
2. Compares `sparkle:version` in appcast to running app's `CFBundleVersion`
3. If higher version found, downloads the DMG from `enclosure url`
4. Verifies `sparkle:edSignature` against `SUPublicEDKey` from the running app
5. Mounts DMG, replaces app in place

---

## Troubleshooting

### App crashes on launch with "Library not loaded: Sparkle.framework"
The app and Sparkle.framework have different Team IDs. Rebuild without `CODE_SIGN_IDENTITY="-"`.

### QuickLook extension doesn't render markdown
Ad-hoc signed extensions aren't registered by macOS. Rebuild with team signing.

### "Update Error! An error occurred while launching the installer"
The main app is sandboxed but Sparkle's `Installer.xpc` is ad-hoc signed (no Team ID). macOS blocks the XPC launch due to the signing mismatch. Fix: set `ENABLE_APP_SANDBOX = NO` for the MDV target (not the QuickLook target). See "Sandbox Configuration" above.

### Sparkle says "up to date" but new version exists
`sparkle:version` in appcast must be strictly greater than the installed app's `CURRENT_PROJECT_VERSION`.

### Old app still opens after deletion
macOS caches app registrations. Unregister stale copies:
```bash
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -u /path/to/stale/MDV.app
```
