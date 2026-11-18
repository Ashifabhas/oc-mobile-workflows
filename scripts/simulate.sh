#!/usr/bin/env bash
# simulate.sh <app> <minutes> [android|ios] — install the app on the running emulator or booted simulator and loop its
# Maestro flows in random order (SIM_MODE=short), or run one journey in a single app session (SIM_MODE=long).
# Env: OC_BASE_URL, MAESTRO_SEED_PASSWORD, ATATUS_* (optional), SIM_INCLUDE_FAILURES=true|false, SIM_FLOWS (regex), SIM_OUT,
# SIM_MODE=short|long, SIM_KIND=work|boot-crash (long only; SIM_FLOWS and SIM_INCLUDE_FAILURES apply to short only).
set -euo pipefail

APP="${1:?app}"
MINUTES="${2:?minutes}"
PLATFORM="${3:-android}"
MODE="${SIM_MODE:-short}"
KIND="${SIM_KIND:-work}"
case "$MODE" in short|long) ;; *) echo "SIM_MODE must be short or long" >&2; exit 1 ;; esac
case "$KIND" in work|boot-crash) ;; *) echo "SIM_KIND must be work or boot-crash" >&2; exit 1 ;; esac
REPO="$(cd "$(dirname "$0")/.." && pwd)"
case "$PLATFORM" in
  android) BUILD="apps/$APP/android/$APP.apk" ;;
  ios) BUILD="apps/$APP/ios/$APP.app.zip" ;;
  *) echo "platform must be android or ios" >&2; exit 1 ;;
esac
FLOWS_DIR="$REPO/apps/$APP/maestro"
OUT="${SIM_OUT:-$REPO/out}/$APP"
BASE="${OC_BASE_URL:?OC_BASE_URL}"
BASE="${BASE%/}"

[[ -f "$REPO/$BUILD" ]] || { echo "no $PLATFORM build at $BUILD" >&2; exit 1; }
: "${MAESTRO_SEED_PASSWORD:?MAESTRO_SEED_PASSWORD}"

for svc in user product order inventory payment analytics shipping review; do
  export "MAESTRO_${svc^^}_SERVICE_URL=$BASE/$svc-service"
done
# RUM goes through the platform's /flux ingest to flux, which fans it out to every Atatus Target; the key is the oc_flux_ gate token, not a real license key.
export MAESTRO_ATATUS_LICENSE_KEY="${ATATUS_LICENSE_KEY:-}"
export MAESTRO_ATATUS_SITE=in
export MAESTRO_ATATUS_SERVER_URL="$BASE/flux"
export MAESTRO_ATATUS_ENV="${ATATUS_ENV:-simulation}"
export MAESTRO_CLI_NO_ANALYTICS=1 MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true

if [[ "$PLATFORM" == "android" ]]; then
  adb install -r "$REPO/$BUILD" > /dev/null
  # The launcher ANRs on a freshly booted CI emulator and its dialog covers the app for the whole run; flows start apps directly.
  adb shell pm disable-user --user 0 com.google.android.apps.nexuslauncher > /dev/null
  adb shell settings put secure anr_show_background 0
else
  unpacked="$(mktemp -d)"
  ditto -x -k "$REPO/$BUILD" "$unpacked"
  bundle="$(find "$unpacked" -maxdepth 1 -name '*.app' | head -1)"
  xcrun simctl install booted "$bundle"
  IOS_PROCESS="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist")"
fi
echo "installed $BUILD"

if [[ "$MODE" == "short" ]]; then
  mapfile -t FLOWS < <(
    cd "$FLOWS_DIR"
    ls journeys/*.yaml
    [[ "${SIM_INCLUDE_FAILURES:-true}" == "true" ]] && ls failures/*.yaml
    true
  )
  if [[ -n "${SIM_FLOWS:-}" ]]; then
    mapfile -t FLOWS < <(printf '%s\n' "${FLOWS[@]}" | grep -E "$SIM_FLOWS" || true)
  fi
  (( ${#FLOWS[@]} > 0 )) || { echo "no flows selected for $APP" >&2; exit 1; }
  echo "flows: ${FLOWS[*]}"
  LABEL="short, $MINUTES min"
elif [[ "$KIND" == "boot-crash" ]]; then
  mapfile -t FLOWS < <(cd "$FLOWS_DIR" && ls failures/*crash.yaml 2>/dev/null || true)
  (( ${#FLOWS[@]} == 1 )) || { echo "$APP needs exactly one failures/*crash.yaml for a boot-crash journey" >&2; exit 1; }
  echo "crash flow: ${FLOWS[0]}"
  LABEL="long boot-crash, target $MINUTES min"
else
  mapfile -t FLOWS < <(cd "$FLOWS_DIR" && ls journeys/*.yaml failures/*.yaml 2>/dev/null || true)
  JOURNEYS=()
  ERRORS=()
  for flow in "${FLOWS[@]}"; do
    grep -qE '^[[:space:]]*-[[:space:]]*short-only[[:space:]]*$' "$FLOWS_DIR/$flow" && continue
    case "$flow" in
      journeys/*) JOURNEYS+=("$flow") ;;
      failures/*crash.yaml) ;;
      failures/*) ERRORS+=("$flow") ;;
    esac
  done
  (( ${#JOURNEYS[@]} > 0 )) || { echo "no journeys/ flows for $APP" >&2; exit 1; }
  echo "journeys: ${JOURNEYS[*]}"
  echo "errors: ${ERRORS[*]}"
  LABEL="long work, target $MINUTES min"
fi

device_ok() { [[ "$(adb get-state 2>/dev/null)" == "device" ]]; }
# adb often drops for a moment and is back before we look, so Maestro's own log is the better witness.
# On iOS the device stays up but Maestro's XCTest driver can fail to start or die mid-flow; that run then ends
# without any failed step.
device_dropped() {
  if [[ "$PLATFORM" == "ios" ]]; then
    grep -qE 'iOS driver not ready' "$1.log" || ! grep -qE '\.\.\. FAILED' "$1.log"
    return
  fi
  ! device_ok || grep -rqsE 'device offline|DeviceServerDiedException' "$1"
}

recover_device() {
  [[ "$PLATFORM" == "ios" ]] && { echo "iOS driver failed, retrying" >&2; return 0; }
  echo "device dropped, reconnecting" >&2
  adb reconnect > /dev/null 2>&1 || true
  timeout 120 adb wait-for-device || return 1
  until [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do sleep 2; done
}

mkdir -p "$OUT"
if [[ "$PLATFORM" == "android" ]]; then
  adb logcat -c
  adb logcat -v threadtime > "$OUT/logcat.txt" 2>&1 &
else
  xcrun simctl spawn booted log stream --style compact --level debug --predicate "process == \"$IOS_PROCESS\"" > "$OUT/device.log" 2>&1 &
fi
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT
RESULTS="$OUT/results.tsv"
if [[ "$MODE" == "long" ]]; then
  echo "# mode=long kind=$KIND target_minutes=$MINUTES" > "$RESULTS"
else
  echo "# mode=short target_minutes=$MINUTES" > "$RESULTS"
fi
deadline=$(( $(date +%s) + MINUTES * 60 ))
run=0

run_flow() {
  local flow="$1" dir started status
  run=$((run + 1))
  dir="$OUT/$(printf '%04d' "$run")-$(basename "$flow" .yaml)"
  started=$(date +%s)
  status=pass
  if ! maestro test --no-ansi --test-output-dir "$dir" "$FLOWS_DIR/$flow" > "$dir.log" 2>&1; then
    status=fail
    # Retry once only when the emulator dropped the device; an app or backend failure is a valid simulation outcome.
    if device_dropped "$dir" && recover_device; then
      status=retried-fail
      maestro test --no-ansi --test-output-dir "$dir-retry" "$FLOWS_DIR/$flow" > "$dir-retry.log" 2>&1 && status=retried-pass
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' "$run" "$flow" "$status" "$(( $(date +%s) - started ))" >> "$RESULTS"
  echo "[$run] $flow: $status ($(( $(date +%s) - started ))s)"
}

think_time() {
  if (( RANDOM % 100 < 80 )); then echo $(( 3 + RANDOM % 13 )); else echo $(( 20 + RANDOM % 71 )); fi
}

if [[ "$MODE" == "short" ]]; then
  while (( $(date +%s) < deadline )); do
    mapfile -t ROUND < <(printf '%s\n' "${FLOWS[@]}" | shuf)
    for flow in "${ROUND[@]}"; do
      (( $(date +%s) < deadline )) || break
      run_flow "$flow"
    done
  done
elif [[ "$KIND" == "boot-crash" ]]; then
  run_flow "${FLOWS[0]}"
else
  run_flow common/launch.yaml
  run_flow common/login.yaml
  # The last flow and the flush have to end before the job's timeout.
  stop_at=$(( deadline - (MINUTES * 12 < 300 ? MINUTES * 12 : 300) ))
  export MAESTRO_LONG=true
  while (( $(date +%s) < stop_at )); do
    if (( ${#ERRORS[@]} == 0 || RANDOM % 100 < 80 )); then
      flow="${JOURNEYS[RANDOM % ${#JOURNEYS[@]}]}"
    else
      flow="${ERRORS[RANDOM % ${#ERRORS[@]}]}"
    fi
    run_flow "$flow"
    left=$(( stop_at - $(date +%s) ))
    (( left > 0 )) || break
    pause=$(think_time)
    sleep $(( pause < left ? pause : left ))
  done
  run_flow common/flush.yaml
fi

passed=$(grep -cE $'\t(pass|retried-pass)\t' "$RESULTS" || true)
total=$(grep -c $'\t' "$RESULTS" || true)
echo "$APP ($PLATFORM, $LABEL): $passed/$total flows passed"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### $APP ($PLATFORM, $LABEL): $passed/$total flows passed"
    echo
    echo "| # | Flow | Result | Seconds |"
    echo "|---|---|---|---|"
    awk -F'\t' 'NF >= 4 { printf "| %s | `%s` | %s | %s |\n", $1, $2, $3, $4 }' "$RESULTS"
    echo
  } >> "$GITHUB_STEP_SUMMARY"
fi

# common/ flows of a work journey pass even when every picked flow fails, so they do not count towards a green job.
picked_passed=$(grep -vE $'^[0-9]+\tcommon/' "$RESULTS" | grep -cE $'\t(pass|retried-pass)\t' || true)
(( total > 0 && picked_passed > 0 ))
