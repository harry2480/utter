#!/usr/bin/env bash
# 配布用（Release）のビルド設定の検査。署名せずに、Developer ID 署名・公証で必要になる設定を確かめる。
# - Hardened Runtime が有効（公証の必須条件）
# - Entitlement のファイルがあり、plist として正しい
# - App Sandbox を有効にしていない（他アプリへの AX 操作のため使わない）
# - マイクの用途説明があるなら、Hardened Runtime で録音に要る audio-input の Entitlement もある
# 前提: xcodegen generate 済み（scripts/verify.sh が先に生成する）。秘密情報は使わない。
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

project="Apps/macOS/Utter.xcodeproj"
if [[ ! -d "$project" ]]; then
  echo "$project がありません。先に xcodegen generate --spec Apps/macOS/project.yml を実行してください。" >&2
  exit 1
fi

settings="$(xcodebuild -project "$project" -target UtterMac -configuration Release -showBuildSettings -disableAutomaticPackageResolution)"

# xcodebuild -showBuildSettings の「    KEY = value」から値を取り出す（ない・空なら空文字）
setting() {
  printf '%s\n' "$settings" | sed -n "s/^ *$1 = //p" | head -n 1
}

failures=0
fail() {
  echo "Release 構成: $1" >&2
  failures=$((failures + 1))
}

if [[ "$(setting ENABLE_HARDENED_RUNTIME)" != "YES" ]]; then
  fail "ENABLE_HARDENED_RUNTIME が YES ではありません（公証に必要。Apps/macOS/project.yml の configs.Release）。"
fi

entitlements_setting="$(setting CODE_SIGN_ENTITLEMENTS)"
if [[ -z "$entitlements_setting" ]]; then
  fail "CODE_SIGN_ENTITLEMENTS が設定されていません。"
else
  entitlements="Apps/macOS/$entitlements_setting"
  if [[ ! -f "$entitlements" ]]; then
    fail "Entitlement のファイルがありません: $entitlements"
  elif ! plutil -lint -s "$entitlements"; then
    fail "Entitlement のファイルが plist として読めません: $entitlements"
  else
    # 値が true のときだけ有効とみなす（キーがない・false なら無効）
    entitlement_enabled() {
      [[ "$(/usr/libexec/PlistBuddy -c "Print :$1" "$entitlements" 2>/dev/null)" == "true" ]]
    }
    if entitlement_enabled com.apple.security.app-sandbox; then
      fail "App Sandbox が有効です（他アプリへの AX 操作のため使わない。docs/ビルド・配布規約.md）。"
    fi
    if [[ -n "$(setting INFOPLIST_KEY_NSMicrophoneUsageDescription)" ]] &&
      ! entitlement_enabled com.apple.security.device.audio-input; then
      fail "マイクの用途説明があるのに $entitlements に com.apple.security.device.audio-input = true がありません（Hardened Runtime では録音できない）。"
    fi
  fi
fi

if ((failures > 0)); then
  exit 1
fi
echo "Release 構成の署名関連の設定に問題はありません。"
