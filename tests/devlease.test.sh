#!/bin/bash
# Tests for the devlease hook. Run: bash tests/devlease.test.sh
DEVLEASE="$(dirname "$0")/../bin/devlease"
DEVLEASE_DIR="$(mktemp -d)"
export DEVLEASE_DIR
export DEVLEASE_WAIT=0
export DEVLEASE_DEVICES="emulator-5554 emulator-5556 R58MSAMPLE01"
trap 'rm -rf "$DEVLEASE_DIR"' EXIT

pass=0; fail=0

# Without this, every `allow` assertion passes vacuously on a missing script.
[ -x "$DEVLEASE" ] || { echo "FATAL: $DEVLEASE missing or not executable"; exit 1; }

# hook <session> <command> [env assignments...]
hook() {
  local sess="$1" cmd="$2"; shift 2
  env "$@" python3 -c '
import json,sys
print(json.dumps({"session_id":sys.argv[1],"cwd":"/tmp/wt","tool_name":"Bash",
                  "tool_input":{"command":sys.argv[2]}}))' "$sess" "$cmd" \
    | env "$@" "$DEVLEASE" hook
}

# hook_cwd <session> <cwd> <command> [env assignments...]
hook_cwd() {
  local sess="$1" wd="$2" cmd="$3"; shift 3
  env "$@" python3 -c '
import json,sys
print(json.dumps({"session_id":sys.argv[1],"cwd":sys.argv[2],"tool_name":"Bash",
                  "tool_input":{"command":sys.argv[3]}}))' "$sess" "$wd" "$cmd" \
    | env "$@" "$DEVLEASE" hook
}

check() { # check <desc> <output> <grep-mode: deny|allow|warn> [substring]
  local desc="$1" out="$2" mode="$3" sub="${4:-}" ok=1
  case "$mode" in
    deny)  echo "$out" | grep -q '"permissionDecision": *"deny"' || ok=0 ;;
    allow) echo "$out" | grep -q '"permissionDecision": *"deny"' && ok=0 ;;
    warn)  echo "$out" | grep -q 'additionalContext' || ok=0 ;;
  esac
  [ -n "$sub" ] && { echo "$out" | grep -qi -- "$sub" || ok=0; }
  if [ $ok -eq 1 ]; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL: $desc"; echo "  got: $out"
  fi
}

reset() { rm -rf "${DEVLEASE_DIR:?}"/*; }

# --- gating: what is and is not a device command ---
reset
check "assemble is ungated" "$(hook A './gradlew assembleMaestroDebug')" allow
check "unit tests ungated" "$(hook A './gradlew testDebugUnitTest')" allow
check "yaml generation ungated" "$(hook A './gradlew :maestro:generateYamls')" allow
check "adb devices ungated" "$(hook A 'adb devices -l')" allow
check "building the test apk is ungated" \
  "$(hook A './gradlew assembleDebugAndroidTest')" allow
check "lint on a maestro variant is ungated" \
  "$(hook A './gradlew lintVitalMaestroRelease')" allow
check "maestro start-device ungated" "$(hook A 'maestro start-device --platform android')" allow

# --- always-denied globals ---
reset
check "kill-server denied" "$(hook A 'adb kill-server')" deny "other agents"
check "adb root denied" "$(hook A 'adb -s emulator-5554 root')" deny "other agents"
check "adb -d denied" "$(hook A 'adb -d shell ls')" deny "other agents"
# -d/-e mean "any device"/"any emulator" only in the subcommand position; elsewhere
# they are ordinary flags (allow-downgrade, string extra) on a device-scoped command.
check "install -d is not a global op" \
  "$(hook A 'adb -s emulator-5554 install -d app.apk')" allow
check "am start -e extra is not a global op" \
  "$(hook A 'adb -s emulator-5554 shell am start -n com.x/.M -e key val')" allow
check "dumpsys usb is not a global op" \
  "$(hook A 'adb -s emulator-5554 shell dumpsys usb')" allow

# --- serial resolution ---
reset
check "adb -s acquires" "$(hook A 'adb -s emulator-5554 shell ls')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: lease dir not created"; }

reset
check "ambiguous target denied" "$(hook A './gradlew installMaestroDebug')" deny "ANDROID_SERIAL"
reset
check "ANDROID_SERIAL resolves" \
  "$(hook A './gradlew installMaestroDebug' ANDROID_SERIAL=emulator-5554)" allow
reset
check "inline ANDROID_SERIAL resolves" \
  "$(hook A 'ANDROID_SERIAL=emulator-5554 ./gradlew installMaestroDebug')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: inline ANDROID_SERIAL not read"; }
reset
check "maestro --device space form resolves" \
  "$(hook A "\$HOME/.maestro/bin/maestro --device emulator-5554 test /tmp/f.yaml")" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: maestro --device serial not used"; }
reset
check "android --device= resolves" \
  "$(hook A 'android install --device=emulator-5554 --apks=app.apk')" allow

# --- the holder is told how to give the device back ---
reset
check "fresh acquire tells holder to release" \
  "$(hook A 'adb -s emulator-5554 shell ls')" warn "devlease release"
echo "$(hook A 'adb -s emulator-5554 shell ls')" | grep -qi "devlease release" \
  && { fail=$((fail+1)); echo "FAIL: release reminder repeated on renewal"; } || pass=$((pass+1))

# --- mutual exclusion ---
reset
hook A 'adb -s emulator-5554 shell ls' >/dev/null
check "other session denied" "$(hook B 'adb -s emulator-5554 shell ls')" deny "held by"
check "owner re-entry allowed" "$(hook A 'adb -s emulator-5554 shell ls')" allow
check "other device still free" "$(hook B 'adb -s emulator-5556 shell ls')" allow

# --- release and steal ---
reset
hook A 'adb -s emulator-5554 shell ls' >/dev/null
CLAUDE_CODE_SESSION_ID=B "$DEVLEASE" release emulator-5554 >/dev/null 2>&1
check "non-owner release is a no-op" "$(hook B 'adb -s emulator-5554 shell ls')" deny "held by"
CLAUDE_CODE_SESSION_ID=A "$DEVLEASE" release emulator-5554 >/dev/null
check "owner release frees it" "$(hook B 'adb -s emulator-5554 shell ls')" allow
"$DEVLEASE" steal emulator-5554 >/dev/null
check "steal frees it" "$(hook A 'adb -s emulator-5554 shell ls')" allow

# --- idle TTL reap ---
reset
hook A 'adb -s emulator-5554 shell ls' >/dev/null
touch -t 200001010000 "$DEVLEASE_DIR/emulator-5554"
check "expired lease is reaped" "$(hook B 'adb -s emulator-5554 shell ls')" allow

# --- last-writer stamp ---
reset
hook A 'adb -s emulator-5554 shell ls' >/dev/null
CLAUDE_CODE_SESSION_ID=A "$DEVLEASE" release emulator-5554 >/dev/null
hook B 'adb -s emulator-5554 shell ls' >/dev/null
CLAUDE_CODE_SESSION_ID=B "$DEVLEASE" release emulator-5554 >/dev/null
check "returning agent warned of state change" \
  "$(hook A 'adb -s emulator-5554 shell ls')" warn "state changed"
check "renewal does not re-warn" \
  "$(hook A 'adb -s emulator-5554 shell ls')" allow
echo "$(hook A 'adb -s emulator-5554 shell ls')" | grep -qi "state changed" \
  && { fail=$((fail+1)); echo "FAIL: re-warned on renewal"; } || pass=$((pass+1))

# --- core takes a lease but never dictates which device is appropriate ---
reset
check "maestro on a physical device is allowed by default" \
  "$(hook A 'maestro --device R58MSAMPLE01 test /tmp/f.yaml')" allow
[ -d "$DEVLEASE_DIR/R58MSAMPLE01" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: maestro took no lease"; }
reset
check "a project's own gradle task is not core-gated" \
  "$(hook A './gradlew :maestro:runSelectedTests -Pdevice=emulator-5554')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && { fail=$((fail+1)); echo "FAIL: core gated a project-specific task"; } || pass=$((pass+1))
check "adb on physical is fine" "$(hook A 'adb -s R58MSAMPLE01 shell ls')" allow

# --- batch tool input shape ---
reset
out=$(python3 -c '
import json
print(json.dumps({"session_id":"A","cwd":"/tmp/wt",
  "tool_name":"mcp__plugin_context-mode_context-mode__ctx_batch_execute",
  "tool_input":{"commands":[{"label":"x","command":"adb -s emulator-5554 shell ls"}]}}))' \
  | "$DEVLEASE" hook)
check "batch_execute is gated too" "$out" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: batch command not gated"; }

# --- project and home config ---
PROJ="$(mktemp -d)"; FAKEHOME="$(mktemp -d)"
cat > "$PROJ/.devlease.json" <<'JSON'
{"denied": ["scripts/ci-only\\.sh"],
 "gated": ["flutter\\s+run"],
 "emulator_only": ["flutter\\s+drive"]}
JSON
echo '{"denied": ["wipe-the-fleet"]}' > "$FAKEHOME/.devlease.json"

reset
check "config denied pattern is refused" \
  "$(hook_cwd A "$PROJ" './scripts/ci-only.sh')" deny
check "config gated pattern takes a lease" \
  "$(hook_cwd A "$PROJ" 'flutter run --device emulator-5554')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: config gated pattern took no lease"; }
reset
check "config emulator_only rejects a physical serial" \
  "$(hook_cwd A "$PROJ" 'flutter drive --device R58MSAMPLE01')" deny "physical"
check "config emulator_only accepts an emulator" \
  "$(hook_cwd A "$PROJ" 'flutter drive --device emulator-5554')" allow

reset
check "a project without config is unaffected" \
  "$(hook_cwd A /tmp 'flutter run --device emulator-5554')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && { fail=$((fail+1)); echo "FAIL: gated an unconfigured project"; } || pass=$((pass+1))

reset
check "home config applies anywhere" \
  "$(hook_cwd A /tmp 'wipe-the-fleet --yes' HOME="$FAKEHOME")" deny
check "project and home rules both apply" \
  "$(hook_cwd A "$PROJ" './scripts/ci-only.sh' HOME="$FAKEHOME")" deny

# A project-specific Gradle task, gated and emulator-restricted by config alone.
cat > "$PROJ/.devlease.json" <<'JSON'
{"emulator_only": ["gradlew\\b[^|;&]*?:?maestro:run(?:All|Selected)Tests\\b"]}
JSON
reset
check "config reaches -Pdevice for a project gradle task" \
  "$(hook_cwd A "$PROJ" './gradlew :maestro:runSelectedTests -Pdevice=emulator-5554')" allow
[ -d "$DEVLEASE_DIR/emulator-5554" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: -Pdevice serial not used"; }
reset
check "config blocks that task on a physical device" \
  "$(hook_cwd A "$PROJ" './gradlew :maestro:runSelectedTests -Pdevice=R58MSAMPLE01')" deny "physical"

echo 'not json {{{' > "$PROJ/.devlease.json"
check "malformed config does not break the gate" \
  "$(hook_cwd A "$PROJ" 'adb -s emulator-5554 shell ls')" allow
rm -rf "$PROJ" "$FAKEHOME"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
