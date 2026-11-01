#!/bin/bash
# #233 の待機セッション方式の UI テストを、つないだ iPhone で動かす。本番の検証手順ではない。
# 実行中は Mac のスピーカーから日本語の合成音声を流し続け、iPhone のマイクに拾わせる。
#
# 使い方: Verification/iOSKeyboardProbe/run-ui-tests.sh <テスト名> [<テスト名> ...]
#   例: run-ui-tests.sh testSingleCycle
# 環境変数: UTTER_DEVICE_ID（既定はつないでいる最初の iPhone）
set -euo pipefail

cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ "$#" -eq 0 ]; then
  echo "テスト名を1つ以上指定する（例: testSingleCycle）" >&2
  exit 2
fi

device="${UTTER_DEVICE_ID:-}"
if [ -z "$device" ]; then
  # 表示の形は版で変わるため、--json-output の JSON から物理端末を選ぶ。xcodebuild には UDID を渡し、
  # UDID がなければ CoreDevice の identifier を渡す
  device="$(xcrun devicectl list devices --quiet --json-output /dev/stdout 2>/dev/null \
    | /usr/bin/python3 -I -c '
import json, sys
devices = json.load(sys.stdin).get("result", {}).get("devices", [])
for d in devices:
    hardware = d.get("hardwareProperties", {})
    if hardware.get("reality") == "physical":
        print(hardware.get("udid") or d.get("identifier", ""))
        break
' || true)"
fi
if [ -z "$device" ]; then
  echo "つないでいる iPhone が見つからない" >&2
  exit 1
fi

xcodegen generate --spec project.yml >/dev/null

only=()
for name in "$@"; do
  only+=("-only-testing:UtterKeyboardProbeUITests/VoiceSessionUITests/${name}")
done

# 合成音声を流し続ける（終わったら止める）
(
  while true; do
    say -v Kyoko "明日の会議は十時からです。資料を準備しておいてください。"
    sleep 1
  done
) &
speaker=$!
trap 'kill "$speaker" 2>/dev/null; killall say 2>/dev/null || true' EXIT

xcodebuild test \
  -project UtterKeyboardProbe.xcodeproj -scheme UtterKeyboardProbe \
  -destination "id=${device}" -allowProvisioningUpdates \
  "${only[@]}" 2>&1 | tee "${TMPDIR:-/tmp}/utter-ui-tests.log" | grep -E "UTTER-RESULT|error:|Test Case|\*\* TEST" || true
