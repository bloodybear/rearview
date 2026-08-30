#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SCRIPT_PATH="$0"
PACKAGE_MODE="default"
typeset -a PACKAGE_ARGUMENTS
PACKAGE_ARGUMENTS=()

usage() {
    print -u2 -- "usage: $SCRIPT_PATH [dev] [zip] [dmg]"
    exit 2
}

for argument in "$@"; do
    case "$argument" in
        dev)
            PACKAGE_MODE="dev"
            PACKAGE_ARGUMENTS+=(dev)
            ;;
        zip|dmg)
            PACKAGE_ARGUMENTS+=("$argument")
            ;;
        *)
            usage
            ;;
    esac
done

if [[ "$PACKAGE_MODE" == "dev" ]]; then
    APP="$ROOT/dist/Rearview-dev.app"
else
    APP="$ROOT/dist/Rearview.app"
fi
APP_EXECUTABLE="$APP/Contents/MacOS/Rearview"

if [[ -z "${SDKROOT:-}" ]]; then
    SDKROOT=$(/usr/bin/xcrun --sdk macosx --show-sdk-path) || {
        print -u2 -- "error: unable to locate the macOS SDK with xcrun"
        exit 1
    }
fi
if [[ ! -d "$SDKROOT" ]]; then
    print -u2 -- "error: SDKROOT does not point to a directory: $SDKROOT"
    exit 1
fi
export SDKROOT

print -- "Running Swift unit tests"
SDKROOT="$SDKROOT" \
CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache" \
swift test --disable-sandbox \
    --cache-path "$ROOT/.swiftpm-cache" \
    --config-path "$ROOT/.swiftpm-config" \
    --security-path "$ROOT/.swiftpm-security"

stop_running_app() {
    local pid executable_path deadline
    local -a stopped_pids
    stopped_pids=()

    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        executable_path=$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null \
            | /usr/bin/sed -n 's/^n//p' | /usr/bin/head -n 1)
        [[ "$executable_path" == "$APP_EXECUTABLE" ]] || continue

        print -- "Stopping Rearview PID $pid: $executable_path"
        /bin/kill "$pid"
        stopped_pids+=("$pid")
    done < <(/usr/bin/pgrep -x Rearview 2>/dev/null || true)

    if (( ${#stopped_pids[@]} == 0 )); then
        print -- "No running app found at: $APP_EXECUTABLE"
        return
    fi

    for pid in "${stopped_pids[@]}"; do
        deadline=$(( $(/bin/date +%s) + 5 ))
        while /bin/kill -0 "$pid" 2>/dev/null; do
            if (( $(/bin/date +%s) >= deadline )); then
                print -u2 -- "error: timed out waiting for Rearview PID $pid to stop"
                exit 1
            fi
            /bin/sleep 1
        done
    done
}

stop_running_app
"$ROOT/scripts/package_app.sh" "${PACKAGE_ARGUMENTS[@]}"
"$APP_EXECUTABLE" --self-test
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/open "$APP"

print -- "Launched app: $APP"
