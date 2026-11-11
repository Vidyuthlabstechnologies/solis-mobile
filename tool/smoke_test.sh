#!/usr/bin/env bash
# Smoke test for an installed SOLIS APK on a running emulator or phone:
#   tool/smoke_test.sh <apk> <screenshot dir>
# Opens the app, taps "Use demo account", opens the first patient, and fails
# if the app crashes or a step's text never appears.
set -uo pipefail
APK=$1; OUT=$2; PKG=com.solis.clinical.solis_mobile
mkdir -p "$OUT"
fail() { echo "SMOKE FAIL: $*"; adb logcat -d > "$OUT/logcat.txt"; shot fail; exit 1; }
shot() { adb exec-out screencap -p > "$OUT/$1.png" || true; }
dump() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb shell cat /sdcard/ui.xml 2>/dev/null; }
# Waits for text (in text or content-desc) and prints the centre of its bounds.
find_text() {
  local want=$1 tries=${2:-30} xml line
  for _ in $(seq "$tries"); do
    xml=$(dump)
    line=$(echo "$xml" | tr '>' '\n' | grep -i -m1 -E "(text|content-desc)=\"[^\"]*$want" || true)
    if [ -n "$line" ]; then
      echo "$line" | sed -E 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1 \2 \3 \4/' | awk '{print int(($1+$3)/2), int(($2+$4)/2)}'
      return 0
    fi
    alive || fail "app stopped while waiting for '$want'"
    sleep 2
  done
  return 1
}
alive() { [ -n "$(adb shell pidof $PKG | tr -d '\r')" ]; }
tap_text() { local xy; xy=$(find_text "$1" "${2:-30}") || fail "never saw '$1'"; adb shell input tap $xy; sleep 2; }

adb logcat -c
adb install -r -g "$APK" || fail "install failed"
adb shell dumpsys package $PKG | grep -m1 versionName | tee "$OUT/version.txt"
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null
sleep 8
alive || fail "app did not start"
shot 1-start

tap_text "Use demo account" 45
shot 2-demo
# First run may show permission or setup prompts; accept the common ones.
for b in "Allow" "While using the app" "Continue" "Got it"; do
  xy=$(find_text "$b" 2) && adb shell input tap $xy && sleep 2
done
find_text "Patients" 30 >/dev/null || fail "patient list never appeared"
shot 3-patients
tap_text "Margaret" 20 || true
sleep 3
alive || fail "app crashed opening a patient"
shot 4-patient

adb logcat -d > "$OUT/logcat.txt"
if grep -E "FATAL EXCEPTION|Fatal signal" "$OUT/logcat.txt" | grep -q .; then fail "crash in logcat"; fi
echo "SMOKE OK"
