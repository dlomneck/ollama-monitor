#!/bin/bash
set -euo pipefail

cd "$HOME/OllamaMonitor"

SOURCE="Sources/OllamaMonitor/main.swift"
DEV_APP="$HOME/OllamaMonitor/OllamaMonitor.app"
INSTALLED_APP="/Applications/Ollama Monitor.app"
BIN=".build/release/OllamaMonitor"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="backups/release-$STAMP"
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ollama-monitor-release.XXXXXX")"
STAGED_APP="$STAGE_ROOT/Ollama Monitor.app"
INSTALL_STAGE="/Applications/.Ollama Monitor.app.staging-$STAMP"
INSTALL_BACKUP="/Applications/.Ollama Monitor.app.previous-$STAMP"
INSTALL_HELPER="$STAGE_ROOT/install.sh"
SOURCE_UPDATED=0
RELEASE_COMPLETE=0

cleanup() {
    result=$?
    if [ "$result" -ne 0 ] && [ "$SOURCE_UPDATED" -eq 1 ] && [ "$RELEASE_COMPLETE" -eq 0 ]; then
        cp "$BACKUP/main.swift" "$SOURCE"
        echo "Release did not complete; restored source version from backup."
    fi
    rm -rf "$STAGE_ROOT"
    exit "$result"
}
trap cleanup EXIT

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
SOURCE_UPDATED=1

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

# Assemble and verify a complete staged bundle before touching either app copy.
ditto "$DEV_APP" "$STAGED_APP"
cp "$BIN" "$STAGED_APP/Contents/MacOS/OllamaMonitor"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_VERSION" "$STAGED_APP/Contents/Info.plist"
if [ ! -x "$STAGED_APP/Contents/MacOS/OllamaMonitor" ]; then
    echo "ERROR: Staged executable is missing or not executable."
    exit 1
fi

STAGE_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED_APP/Contents/Info.plist")"
STAGE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$STAGED_APP/Contents/Info.plist")"
if [ "$STAGE_SHORT" != "$NEW_VERSION" ] || [ "$STAGE_BUILD" != "$NEW_VERSION" ]; then
    echo "ERROR: Staged bundle version verification failed."
    exit 1
fi

# Stage the full application in /Applications, then swap it into place. Keep a
# previous installed bundle as a rollback copy if the final move fails.
if [ -d "$INSTALLED_APP" ]; then
    cat > "$INSTALL_HELPER" <<'SH'
#!/bin/bash
set -euo pipefail
staged_app="$1"
install_stage="$2"
installed_app="$3"
install_backup="$4"
ditto "$staged_app" "$install_stage"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$install_stage/Contents/Info.plist" >/dev/null
if [ -d "$installed_app" ]; then
    mv "$installed_app" "$install_backup"
    if ! mv "$install_stage" "$installed_app"; then
        mv "$install_backup" "$installed_app"
        echo "Install swap failed; restored prior installed app." >&2
        exit 1
    fi
fi
SH
    chmod 700 "$INSTALL_HELPER"
    /usr/bin/osascript \
        -e 'on run argv' \
        -e 'set commandText to "/bin/bash " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv) & " " & quoted form of (item 5 of argv)' \
        -e 'do shell script commandText with administrator privileges' \
        -e 'end run' \
        "$INSTALL_HELPER" "$STAGED_APP" "$INSTALL_STAGE" "$INSTALLED_APP" "$INSTALL_BACKUP"
    echo "Updated installed app: $INSTALLED_APP"
else
    echo "No installed copy found at $INSTALLED_APP; development app will be updated."
fi

# Update the development bundle only after install staging and swap succeeded.
cp "$BIN" "$DEV_APP/Contents/MacOS/OllamaMonitor"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$DEV_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_VERSION" "$DEV_APP/Contents/Info.plist"
RELEASE_COMPLETE=1

echo
echo "Release successful."
echo "Version: $NEW_VERSION"
echo "Development app: $DEV_APP"
if [ -d "$INSTALLED_APP" ]; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_APP/Contents/Info.plist"
fi
echo "Backup: $BACKUP"
if [ -d "$INSTALL_BACKUP" ]; then
    echo "Previous installed app retained at: $INSTALL_BACKUP"
fi
