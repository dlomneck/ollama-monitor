#!/bin/bash
set -euo pipefail

cd "$HOME/OllamaMonitor"

SOURCE="Sources/OllamaMonitor/main.swift"
DEV_APP="$HOME/OllamaMonitor/OllamaMonitor.app"
INSTALLED_APP="/Applications/Ollama Monitor.app"
BIN=".build/release/OllamaMonitor"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="backups/release-$STAMP"

mkdir -p "$BACKUP"

cp "$SOURCE" "$BACKUP/main.swift"
if [ -f "$DEV_APP/Contents/Info.plist" ]; then
    cp "$DEV_APP/Contents/Info.plist" "$BACKUP/dev-Info.plist"
fi
if [ -f "$INSTALLED_APP/Contents/Info.plist" ]; then
    cp "$INSTALLED_APP/Contents/Info.plist" "$BACKUP/installed-Info.plist"
fi

OLD_VERSION="$(sed -nE 's/.*Text\("Version ([0-9]+\.[0-9]+)"\).*/\1/p' "$SOURCE" | head -1)"
if [ -z "$OLD_VERSION" ]; then
    echo "ERROR: Could not read About version from source."
    exit 1
fi

MAJOR="${OLD_VERSION%%.*}"
MINOR="${OLD_VERSION#*.}"
NEW_VERSION="$MAJOR.$((MINOR + 1))"

echo "Preparing Ollama Monitor v$NEW_VERSION"

python3 - "$SOURCE" "$NEW_VERSION" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text()
updated, count = re.subn(
    r'Text\("Version [0-9]+\.[0-9]+"\)',
    f'Text("Version {version}")',
    text,
    count=1
)
if count != 1:
    raise SystemExit("ERROR: About version update failed.")
path.write_text(updated)
PY

if ! swift build -c release; then
    echo "BUILD FAILED. Restoring source from backup."
    cp "$BACKUP/main.swift" "$SOURCE"
    exit 1
fi

if [ ! -x "$BIN" ]; then
    echo "ERROR: Release executable missing after build."
    cp "$BACKUP/main.swift" "$SOURCE"
    exit 1
fi

if [ ! -d "$DEV_APP/Contents/MacOS" ] || [ ! -f "$DEV_APP/Contents/Info.plist" ]; then
    echo "ERROR: Development app bundle is missing or incomplete."
    cp "$BACKUP/main.swift" "$SOURCE"
    exit 1
fi

# Update the development bundle only after the successful build.
cp "$BIN" "$DEV_APP/Contents/MacOS/OllamaMonitor"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$DEV_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_VERSION" "$DEV_APP/Contents/Info.plist"

# Verify the development bundle metadata before installing.
DEV_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEV_APP/Contents/Info.plist")"
DEV_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEV_APP/Contents/Info.plist")"
if [ "$DEV_SHORT" != "$NEW_VERSION" ] || [ "$DEV_BUILD" != "$NEW_VERSION" ]; then
    echo "ERROR: Development bundle version verification failed."
    exit 1
fi

# Replace the installed bundle only after the release build is verified.
if [ -d "$INSTALLED_APP" ]; then
    sudo ditto "$DEV_APP" "$INSTALLED_APP"
    echo "Updated installed app: $INSTALLED_APP"
else
    echo "No installed copy found at $INSTALLED_APP; development app was updated."
fi

echo
echo "Release successful."
echo "Version: $NEW_VERSION"
echo "Development app: $DEV_APP"
if [ -d "$INSTALLED_APP" ]; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_APP/Contents/Info.plist"
fi
echo "Backup: $BACKUP"
