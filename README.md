# NeverDrop

macOS menu-bar app for visioconference and phone call transcription with speaker matching (diarization).

- **Tech:** Swift 5, macOS 15+, SwiftUI + AppKit, CoreAudio, WhisperKit
- **Build system:** [XcodeGen](https://github.com/yonaskolb/XcodeGen) + Swift Package Manager

## Prerequisites

- macOS 15+
- Xcode 16+ (with command-line tools installed)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Quick Start (local, unsigned)

```bash
make dmg
```

This will:
1. Generate the Xcode project from `project.yml`
2. Build a Release archive
3. Package the app into `build/NeverDrop-0.1.0.dmg`

Individual steps are also available:

```bash
make generate   # only regenerate the .xcodeproj
make build      # generate + build Release archive
make clean      # remove all build artifacts
```

### Installing the unsigned DMG

Open the DMG and drag **NeverDrop.app** into **Applications**.

Because the app is unsigned, macOS Gatekeeper will block the first launch.
To bypass: right-click the app → **Open**, or go to **System Settings → Privacy & Security → Open Anyway**.

## Distribution Build (signed + notarized)

Distributing to other users requires an [Apple Developer Program](https://developer.apple.com/programs/) account ($99/year).

### 1. Build a signed archive

```bash
xcodegen generate

xcodebuild archive \
  -project NeverDrop.xcodeproj \
  -scheme NeverDrop \
  -configuration Release \
  -archivePath build/NeverDrop.xcarchive \
  CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAM_ID)" \
  DEVELOPMENT_TEAM="YOUR_TEAM_ID"
```

### 2. Export the app

Create an `ExportOptions.plist` at the project root:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
</dict>
</plist>
```

Then export:

```bash
xcodebuild -exportArchive \
  -archivePath build/NeverDrop.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export
```

### 3. Create the DMG

```bash
mkdir -p build/dmg
cp -R build/export/NeverDrop.app build/dmg/
ln -s /Applications build/dmg/Applications

hdiutil create -volname "NeverDrop" \
  -srcfolder build/dmg \
  -ov -format UDZO \
  build/NeverDrop-0.1.0.dmg

rm -rf build/dmg
```

### 4. Notarize and staple

```bash
xcrun notarytool submit build/NeverDrop-0.1.0.dmg \
  --apple-id "you@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password" \
  --wait

xcrun stapler staple build/NeverDrop-0.1.0.dmg
```

The DMG is now ready for distribution — Gatekeeper will allow it without warnings.

## Project Structure

```
NeverDrop/
  App/             Entry point + coordinator (AppDelegate)
  Audio/           System audio + mic capture (CoreAudio)
  Detection/       Call detection state machine + mic monitoring
  Transcription/   WhisperKit inference + transcript file output
  UI/              Menu bar + permission panel (AppKit/SwiftUI)
  Resources/       Info.plist, entitlements
```
