#!/bin/zsh
set -euo pipefail

CONFIG_DIR="$HOME/Library/Application Support/BarControl"
CONFIG_FILE="$CONFIG_DIR/backend-mode.json"
MODE=${1:-}

if [[ -z "$MODE" ]]; then
    MODE=$(/usr/bin/osascript -e 'choose from list {"auto", "ccswitch", "codexpp", "custom"} with title "Bar Control" with prompt "选择供应商后端" default items {"ccswitch"}' -e 'if result is false then error number -128' -e 'item 1 of result')
fi

case "$MODE" in
    auto|ccswitch|codexpp) ;;
    custom)
        DATABASE_PATH=${2:-$(/usr/bin/osascript -e 'text returned of (display dialog "供应商数据库路径" default answer "~/.cc-switch/cc-switch.db")')}
        SETTINGS_PATH=${3:-$(/usr/bin/osascript -e 'text returned of (display dialog "供应商 settings.json 路径" default answer "~/.cc-switch/settings.json")')}
        ;;
    *)
        echo "用法：$0 [auto|ccswitch|codexpp|custom [database-path settings-path]]" >&2
        exit 2
        ;;
esac

/bin/mkdir -p "$CONFIG_DIR"
TEMP_FILE=$(/usr/bin/mktemp "$CONFIG_DIR/backend-mode.XXXXXX")
/usr/bin/plutil -create json "$TEMP_FILE"
/usr/bin/plutil -insert providerBackend -string "$MODE" "$TEMP_FILE"
if [[ "$MODE" == "custom" ]]; then
    /usr/bin/plutil -insert databasePath -string "$DATABASE_PATH" "$TEMP_FILE"
    /usr/bin/plutil -insert settingsPath -string "$SETTINGS_PATH" "$TEMP_FILE"
fi
/bin/chmod 600 "$TEMP_FILE"
/bin/mv "$TEMP_FILE" "$CONFIG_FILE"

/usr/bin/osascript -e 'tell application "Bar Control" to quit' 2>/dev/null || true
/bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/com.remodex.bridge" 2>/dev/null || true
/usr/bin/open -a "Bar Control" 2>/dev/null || true
echo "已保存：$CONFIG_FILE（$MODE）"
