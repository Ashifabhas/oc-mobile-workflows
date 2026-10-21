#!/usr/bin/env bash
# simulate.sh <app> <minutes> — install the app on the running emulator and loop its Maestro flows in random order.
# Env: OC_BASE_URL, MAESTRO_SEED_PASSWORD, ATATUS_* (optional), SIM_INCLUDE_FAILURES=true|false, SIM_FLOWS (regex), SIM_OUT.
set -euo pipefail

APP="${1:?app}"
MINUTES="${2:?minutes}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APK="$REPO/apps/$APP/android/$APP.apk"
FLOWS_DIR="$REPO/apps/$APP/maestro"
OUT="${SIM_OUT:-$REPO/out}/$APP"
BASE="${OC_BASE_URL:?OC_BASE_URL}"
BASE="${BASE%/}"

[[ -f "$APK" ]] || { echo "no APK at apps/$APP/android/$APP.apk" >&2; exit 1; }
: "${MAESTRO_SEED_PASSWORD:?MAESTRO_SEED_PASSWORD}"

for svc in user product order inventory payment analytics shipping review; do
  export "MAESTRO_${svc^^}_SERVICE_URL=$BASE/$svc-service"
done
export MAESTRO_ATATUS_LICENSE_KEY="${ATATUS_LICENSE_KEY:-}"
export MAESTRO_ATATUS_SITE="${ATATUS_SITE:-in}"
export MAESTRO_ATATUS_SERVER_URL="${ATATUS_SERVER_URL:-}"
export MAESTRO_ATATUS_ENV="${ATATUS_ENV:-simulation}"
export MAESTRO_CLI_NO_ANALYTICS=1 MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true

adb install -r "$APK" > /dev/null
echo "installed $APP.apk"
# A slow CI emulator often ANRs the launcher; its system dialog covers the app and fails every flow after it.
adb shell settings put global hide_error_dialogs 1
adb shell settings put secure anr_show_background 0

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

device_ok() { [[ "$(adb get-state 2>/dev/null)" == "device" ]]; }

recover_device() {
  echo "device lost, reconnecting" >&2
  adb reconnect > /dev/null 2>&1 || true
  timeout 120 adb wait-for-device || return 1
  until [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do sleep 2; done
}

mkdir -p "$OUT"
adb logcat -c
adb logcat -v threadtime > "$OUT/logcat.txt" 2>&1 &
LOGCAT_PID=$!
trap 'kill "$LOGCAT_PID" 2>/dev/null || true' EXIT
RESULTS="$OUT/results.tsv"
: > "$RESULTS"
deadline=$(( $(date +%s) + MINUTES * 60 ))
run=0

while (( $(date +%s) < deadline )); do
  mapfile -t ROUND < <(printf '%s\n' "${FLOWS[@]}" | shuf)
  for flow in "${ROUND[@]}"; do
    (( $(date +%s) < deadline )) || break
    run=$((run + 1))
    dir="$OUT/$(printf '%04d' "$run")-$(basename "$flow" .yaml)"
    started=$(date +%s)
    status=pass
    if ! maestro test --no-ansi --test-output-dir "$dir" "$FLOWS_DIR/$flow" > "$dir.log" 2>&1; then
      status=fail
      # Retry once only when the emulator dropped the device; an app or backend failure is a valid simulation outcome.
      if ! device_ok && recover_device; then
        status=retried-fail
        maestro test --no-ansi --test-output-dir "$dir-retry" "$FLOWS_DIR/$flow" > "$dir-retry.log" 2>&1 && status=retried-pass
      fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$run" "$flow" "$status" "$(( $(date +%s) - started ))" >> "$RESULTS"
    echo "[$run] $flow: $status ($(( $(date +%s) - started ))s)"
  done
done

passed=$(grep -cE $'\t(pass|retried-pass)\t' "$RESULTS" || true)
total=$(wc -l < "$RESULTS")
echo "$APP: $passed/$total flows passed"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### $APP: $passed/$total flows passed"
    echo
    echo "| # | Flow | Result | Seconds |"
    echo "|---|---|---|---|"
    awk -F'\t' '{ printf "| %s | `%s` | %s | %s |\n", $1, $2, $3, $4 }' "$RESULTS"
    echo
  } >> "$GITHUB_STEP_SUMMARY"
fi

(( total > 0 && passed > 0 ))
