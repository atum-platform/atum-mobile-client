#!/bin/bash
# Polish P3 fix round 2 verification. Run under the heavy-build lock:
#   TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock \
#     docs/ports/polish-p3-chat-feel/locked-r2.sh
# One Debug build-for-testing of HEAD (with the capture harness copied in), the
# three functional UI tests (animations off), then only the capture harness's
# reply-chip test (animations on, recorded). "After" phase only.
set -u
WT=${WT:-$(cd "$(dirname "$0")/../../.." && pwd)}
VOL=${ATUM_BUILD_VOLUME:-/Volumes/AtumTestFlight}
OUT=${P3_ROOT:-$VOL/polish-p3}
UDID=${P3_UDID:-939B69F8-DA11-4E01-ACB3-FD5B3DC2AF4C}
DD=$OUT/dd-r2
SPM=$VOL/spm
HARNESS="$WT/docs/ports/polish-p3-chat-feel/P3ChatFeelCaptureUITests.swift.txt"
export TMPDIR=$VOL/tmp
LOG=$OUT/logs; CTL=$OUT/ctl
mkdir -p "$LOG" "$CTL" "$OUT/after/video" "$TMPDIR"
cd "$WT" || exit 2
echo "lock acquired $(date)"

restore() {
  rm -f "$WT/ios/UITests/P3ChatFeelCaptureUITests.swift"
  git -C "$WT" checkout HEAD -- ios/AtumMobile.xcodeproj
}
trap restore EXIT

watcher() { # records simctl video on the harness's file handshake
  while true; do
    for f in "$CTL"/start.*; do
      [ -e "$f" ] || continue
      name=${f##*/start.}; rm -f "$f"
      phase=${name%%-*}
      xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/$phase/video/${name#*-}.mp4" > "$LOG/r2-rec-$name.log" 2>&1 &
      echo $! > "$CTL/pid.$name"
      sleep 0.6
      touch "$CTL/started.$name"
    done
    for f in "$CTL"/stop.*; do
      [ -e "$f" ] || continue
      name=${f##*/stop.}; rm -f "$f"
      pid=$(cat "$CTL/pid.$name" 2>/dev/null)
      if [ -n "$pid" ]; then
        kill -INT "$pid" 2>/dev/null
        for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
      fi
      rm -f "$CTL/pid.$name"
      touch "$CTL/stopped.$name"
    done
    if [ -e "$CTL/quit" ]; then
      for p in "$CTL"/pid.*; do [ -e "$p" ] && kill -INT "$(cat "$p")" 2>/dev/null; done
      sleep 2; break
    fi
    sleep 0.2
  done
}

run_tests() { # $1 = result name, rest = -only-testing args
  local name=$1; shift
  local xctestrun
  xctestrun=$(ls "$DD"/Build/Products/*.xctestrun | head -1)
  python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$LOG/$name.xcresult"
  TEST_RUNNER_P3_ROOT="$OUT" TEST_RUNNER_P3_PHASE="after" \
  xcodebuild -xctestrun "$xctestrun" \
    -destination "platform=iOS Simulator,id=$UDID" -destination-timeout 60 \
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
    -resultBundlePath "$LOG/$name.xcresult" "$@" test-without-building > "$LOG/$name.log" 2>&1
  local status=$?
  echo "tests $name exit $status $(date)"
  grep -E "Test Case .* (passed|failed)|error:|Executed [0-9]+ tests" "$LOG/$name.log" | head -40
  return $status
}

rm -f "$CTL"/*
cp "$HARNESS" ios/UITests/P3ChatFeelCaptureUITests.swift
(cd ios && xcodegen generate --quiet) || exit 3
echo "build start $(date)"
xcodebuild -project ios/AtumMobile.xcodeproj -scheme AtumMobile -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -destination-timeout 60 \
  -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" -disableAutomaticPackageResolution \
  -jobs 2 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build-for-testing > "$LOG/r2-build.log" 2>&1
BUILD=$?
restore
echo "build exit $BUILD $(date)"
if [ $BUILD -ne 0 ]; then grep -E "error:" "$LOG/r2-build.log" | head -30; exit $BUILD; fi

xcrun simctl shutdown all >/dev/null 2>&1
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 \
  --batteryState charged --batteryLevel 100

run_tests r2-functional \
  -only-testing:AtumMobileUITests/MessageMenuUITests/testPressAndSlideOntoAReactionRunsItWithoutASecondTap \
  -only-testing:AtumMobileUITests/MessageMenuUITests/testMyMessageInMyAssistantChatDeletesAfterAsking \
  -only-testing:AtumMobileUITests/ComposerUITests/testU4SendIsInstantLiteralAndKeepsTheKeyboard
FUNC=$?

xcrun simctl uninstall "$UDID" com.atum.mobile >/dev/null 2>&1
watcher & WPID=$!
run_tests r2-capture -only-testing:AtumMobileUITests/P3ChatFeelCaptureUITests/test04ReplyChipCancel
touch "$CTL/quit"; wait $WPID; rm -f "$CTL"/*

xcrun simctl status_bar "$UDID" clear
xcrun simctl shutdown all
echo "done functional=$FUNC $(date)"
exit $FUNC
