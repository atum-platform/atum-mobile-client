#!/bin/bash
# Polish P3 (chat feel) verification. Run under the heavy-build lock:
#   TMPDIR=$VOL/tmp lockf -k $VOL/.heavy-build.lock docs/ports/polish-p3-chat-feel/locked-capture.sh
# One booted simulator, then:
#   1. "after": Debug build-for-testing of HEAD (with the capture harness copied in),
#      three ComposerAndMenuUITests.swift tests (animations off), the capture class (animations on).
#   2. "before": the P3-owned files checked out from BEFORE_REF, an incremental
#      rebuild into the same derived data, the same capture class.
# The working tree is restored from HEAD at the end, so HEAD must hold the change.
set -u
WT=${WT:-$(cd "$(dirname "$0")/../../.." && pwd)}
VOL=${ATUM_BUILD_VOLUME:-/Volumes/AtumTestFlight}
OUT=${P3_ROOT:-$VOL/polish-p3}
BEFORE_REF=${BEFORE_REF:?set BEFORE_REF to the commit P3 started from}
UDID=${P3_UDID:?set P3_UDID to an iPhone 17 simulator}
DD=$VOL/dd-polish-p3
SPM=$VOL/spm
HARNESS="$WT/docs/ports/polish-p3-chat-feel/P3ChatFeelCaptureUITests.swift.txt"
OWNED="ios/App/Chat/Views/Composer.swift ios/App/Chat/Views/MessageMenu.swift ios/App/Chat/Views/MessageBubbleRow.swift
ios/App/Chat/Views/DeliveryLine.swift ios/App/Chat/Views/ChatRowView.swift ios/App/Chat/Views/EmptyChatGreeting.swift
ios/App/Chat/Views/ChatScreen.swift ios/UITests/ComposerAndMenuUITests.swift"
export TMPDIR=$VOL/tmp
LOG=$OUT/logs; CTL=$OUT/ctl
mkdir -p "$LOG" "$CTL" "$OUT/after/video" "$OUT/before/video" "$TMPDIR"
cd "$WT" || exit 2
echo "lock acquired $(date)"

restore() {
  rm -f "$WT/ios/UITests/P3ChatFeelCaptureUITests.swift"
  git -C "$WT" checkout HEAD -- ios/AtumMobile.xcodeproj $OWNED
}
trap restore EXIT

build() { # $1 = phase
  cp "$HARNESS" ios/UITests/P3ChatFeelCaptureUITests.swift
  (cd ios && xcodegen generate --quiet) || return 3
  echo "build $1 start $(date)"
  xcodebuild -project ios/AtumMobile.xcodeproj -scheme AtumMobile -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" -destination-timeout 60 \
    -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" -disableAutomaticPackageResolution \
    -jobs 2 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build-for-testing > "$LOG/build-$1.log" 2>&1
  local status=$?
  rm -f "$WT/ios/UITests/P3ChatFeelCaptureUITests.swift"
  git -C "$WT" checkout HEAD -- ios/AtumMobile.xcodeproj
  echo "build $1 exit $status $(date)"
  [ $status -eq 0 ] || grep -E "error:" "$LOG/build-$1.log" | head -30
  return $status
}

watcher() { # records simctl video on the harness's file handshake
  while true; do
    for f in "$CTL"/start.*; do
      [ -e "$f" ] || continue
      name=${f##*/start.}; rm -f "$f"
      phase=${name%%-*}
      xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/$phase/video/${name#*-}.mp4" > "$LOG/rec-$name.log" 2>&1 &
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

run_tests() { # $1 = result name, $2 = phase, rest = -only-testing args
  local name=$1 phase=$2; shift 2
  local xctestrun
  xctestrun=$(ls "$DD"/Build/Products/*.xctestrun | head -1)
  python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$LOG/$name.xcresult"
  TEST_RUNNER_P3_ROOT="$OUT" TEST_RUNNER_P3_PHASE="$phase" \
  xcodebuild -xctestrun "$xctestrun" \
    -destination "platform=iOS Simulator,id=$UDID" -destination-timeout 60 \
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
    -resultBundlePath "$LOG/$name.xcresult" "$@" test-without-building > "$LOG/$name.log" 2>&1
  local status=$?
  echo "tests $name exit $status $(date)"
  grep -E "Test Case .* (passed|failed)|error:" "$LOG/$name.log" | head -40
}

pull_probe() { # $1 = phase
  local data
  data=$(xcrun simctl get_app_container "$UDID" com.atum.mobile data 2>/dev/null) || return 0
  cp "$data/Library/Caches/atum-probe.jsonl" "$OUT/$1/atum-probe.jsonl" 2>/dev/null || true
}

boot() {
  xcrun simctl shutdown all >/dev/null 2>&1
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b > /dev/null
  xcrun simctl ui "$UDID" appearance light
  xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 \
    --batteryState charged --batteryLevel 100
}

rm -f "$CTL"/*
build after || exit $?
boot
run_tests functional after \
  -only-testing:AtumMobileUITests/MessageMenuUITests/testPressAndSlideOntoAReactionRunsItWithoutASecondTap \
  -only-testing:AtumMobileUITests/ComposerUITests/testU4SendIsInstantLiteralAndKeepsTheKeyboard \
  -only-testing:AtumMobileUITests/MessageMenuUITests/testMyMessageInMyAssistantChatDeletesAfterAsking
# A selector that matches nothing still "succeeds"; the count must be 3.
grep -E "Executed [0-9]+ tests" "$LOG/functional.log" | tail -1
xcrun simctl uninstall "$UDID" com.atum.mobile >/dev/null 2>&1
watcher & WPID=$!
run_tests capture-after after -only-testing:"${CAPTURE:-AtumMobileUITests/P3ChatFeelCaptureUITests}"
# The send timings come from the full capture (a partial rerun keeps them).
[ -z "${CAPTURE:-}" ] && pull_probe after
touch "$CTL/quit"; wait $WPID; rm -f "$CTL"/*

# SKIP_BEFORE=1: the "before" captures are already on disk and its code is unchanged.
if [ -z "${SKIP_BEFORE:-}" ]; then
  git -C "$WT" checkout "$BEFORE_REF" -- $OWNED
  if build before; then
    xcrun simctl uninstall "$UDID" com.atum.mobile >/dev/null 2>&1
    watcher & WPID=$!
    run_tests capture-before before -only-testing:"${CAPTURE:-AtumMobileUITests/P3ChatFeelCaptureUITests}"
    [ -z "${CAPTURE:-}" ] && pull_probe before
    touch "$CTL/quit"; wait $WPID; rm -f "$CTL"/*
  fi
fi
restore
xcrun simctl status_bar "$UDID" clear
xcrun simctl shutdown all
echo "done $(date)"
exit 0
