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

LOG_DIRECTORY=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/rearview-rebuild.XXXXXX") || {
    print -u2 -- "error: unable to create a temporary rebuild log directory"
    exit 1
}

cleanup_logs() {
    local exit_code=$?
    if (( exit_code == 0 )); then
        /bin/rm -rf -- "$LOG_DIRECTORY"
    fi
}
trap cleanup_logs EXIT

typeset -i STEP_NUMBER=0

run_step() {
    local label="$1"
    shift
    local step_log
    local exit_code

    (( STEP_NUMBER += 1 ))
    step_log="$LOG_DIRECTORY/step-${STEP_NUMBER}.log"
    print -- ""
    print -- "==> $label"

    if "$@" 2>&1 | /usr/bin/tee "$step_log"; then
        print -- "Completed: $label"
        return 0
    else
        exit_code=$?
    fi

    print -u2 -- ""
    print -u2 -- "error: $label failed (exit status $exit_code)"
    print -u2 -- "Full output: $step_log"
    print -u2 -- "Failure summary (success/progress lines omitted):"
    /usr/bin/awk '
        {
            has_freed_pointer = ($0 ~ /freed pointer was not the last allocation/)
            has_diagnostic = ($0 ~ /(^|[[:space:]])error:/ || $0 ~ /fatal error:/ || $0 ~ /unexpected signal code/ || $0 ~ /Abort trap/ || $0 ~ /timed out/ || $0 ~ /(^|[[:space:]])failed([:[:space:]]|$)/ || $0 ~ /(^|[[:space:]])failure([:[:space:]]|$)/)
            if (has_freed_pointer) {
                print "freed pointer was not the last allocation"
                found = 1
            }
            if (has_diagnostic) {
                line = $0
                sub(/[[:space:]]*Test run started.*/, "", line)
                print line
                found = 1
            }
            if (has_freed_pointer || has_diagnostic) next

            if ($0 ~ /Executed [0-9]+ tests?/) next
            if ($0 ~ /Test run started/) next
            if ($0 ~ /Test .* (started|passed|skipped)/) next
            if ($0 ~ /Suite .* (started|passed|skipped)/) next
            if ($0 ~ /Testing Library Version|Target Platform/) next
        }
        END {
            if (!found) print "(no concise error line found; see the full log)"
        }
    ' "$step_log" | /usr/bin/tail -n 20 >&2 || true
    return "$exit_code"
}

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
                return 1
            fi
            /bin/sleep 1
        done
    done
}

run_step "Swift unit tests" \
    /usr/bin/env \
    SDKROOT="$SDKROOT" \
    CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache" \
    swift test --disable-sandbox \
        --cache-path "$ROOT/.swiftpm-cache" \
        --config-path "$ROOT/.swiftpm-config" \
        --security-path "$ROOT/.swiftpm-security"
run_step "Stop running app" stop_running_app
run_step "Package app" "$ROOT/scripts/package_app.sh" "${PACKAGE_ARGUMENTS[@]}"
run_step "Run packaged app self-test" "$APP_EXECUTABLE" --self-test
run_step "Verify app signature" /usr/bin/codesign --verify --deep --strict "$APP"
run_step "Launch packaged app" /usr/bin/open "$APP"

print -- "Launched app: $APP"
