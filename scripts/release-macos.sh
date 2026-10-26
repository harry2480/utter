#!/usr/bin/env bash
# 公式バイナリの作成: アーカイブ → Developer ID 署名 → 公証（notarytool）→ staple → zip / dmg → SHA-256。
# .github/workflows/release.yml から呼ぶ。手元の Mac（maintainer）でも同じ環境変数を渡せば実行できる。
# Phase 0 #47（署名方式の確定）の判定待ちの先行実装（docs/ビルド・配布規約.md「リリース」）。
#
# 必須の環境変数（値はログに出さない）:
#   UTTER_VERSION            版（例: 0.1.0。タグ v0.1.0 の v を除いたもの）→ CFBundleShortVersionString
#   UTTER_BUILD_NUMBER       ビルド番号（正の整数）→ CFBundleVersion
#   UTTER_TEAM_ID            Developer ID 証明書の Team ID
#   UTTER_BUNDLE_ID_PREFIX   Bundle ID の接頭辞（macOS アプリは <接頭辞>.mac）
#   ASC_API_KEY_PATH         App Store Connect API キー（.p8）のファイルのパス
#   ASC_API_KEY_ID           API キーの Key ID
#   ASC_API_ISSUER_ID        API キーの Issuer ID
# 任意:
#   UTTER_KEYCHAIN_PATH      Developer ID 証明書を入れたキーチェーン（CI の一時キーチェーン。未指定なら既定の検索リスト）
#
# 成果物: build/release/ に utter-<版>.zip、utter-<版>.dmg、SHA256SUMS.txt
# set -x は使わない（パスや ID がログに残るのを避ける）。
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

missing=()
for name in UTTER_VERSION UTTER_BUILD_NUMBER UTTER_TEAM_ID UTTER_BUNDLE_ID_PREFIX \
  ASC_API_KEY_PATH ASC_API_KEY_ID ASC_API_ISSUER_ID; do
  if [[ -z "${!name:-}" ]]; then
    missing+=("$name")
  fi
done
if ((${#missing[@]} > 0)); then
  echo "環境変数が設定されていません: ${missing[*]}" >&2
  exit 1
fi
if [[ ! "$UTTER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "UTTER_VERSION は 0.1.0 や 0.1.0-beta.1 の形にしてください。" >&2
  exit 1
fi
if [[ ! "$UTTER_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "UTTER_BUILD_NUMBER は正の整数にしてください。" >&2
  exit 1
fi
if [[ ! -f "$ASC_API_KEY_PATH" ]]; then
  echo "ASC_API_KEY_PATH のファイルがありません。" >&2
  exit 1
fi

# CFBundleShortVersionString は数字と . だけ（プレリリースの接尾辞はタグと Release 名にだけ残す）
marketing_version="${UTTER_VERSION%%-*}"
out_dir="build/release"
archive="$out_dir/utter.xcarchive"
export_dir="$out_dir/export"
app="$export_dir/utter.app"
zip_name="utter-$UTTER_VERSION.zip"
dmg_name="utter-$UTTER_VERSION.dmg"

rm -rf "$out_dir"
mkdir -p "$out_dir"

# 署名に使う証明書を Team ID で1つに絞り、SHA-1 で指定する（名前の前方一致だと別の Team や期限切れの証明書を拾いうる）
keychains=()
if [[ -n "${UTTER_KEYCHAIN_PATH:-}" ]]; then
  keychains=("$UTTER_KEYCHAIN_PATH")
fi
# 空の配列の展開は bash 3.2 の set -u でエラーになるため、要素があるときだけ展開する
identities="$(security find-identity -v -p codesigning ${keychains[@]+"${keychains[@]}"} |
  grep -F "\"Developer ID Application: " | grep -F "($UTTER_TEAM_ID)\"" || true)"
if [[ "$(grep -c . <<<"$identities")" != "1" ]]; then
  echo "Team ID $UTTER_TEAM_ID の有効な Developer ID Application 証明書がちょうど1つ必要です（見つかった数: $(grep -c . <<<"$identities")）。" >&2
  exit 1
fi
signing_identity="$(awk '{ print $2 }' <<<"$identities")"

notarize() {
  # $1: 提出するファイル（zip / dmg）。Accepted でなければ公証のログ（指摘の内容）を出して失敗する
  local submission="$1" result rc=0 submission_id status
  echo "--> 公証に提出: $(basename -- "$submission")"
  # 失敗（Invalid・タイムアウト・通信エラー）でも提出 ID が分かればログを取るため、終了コードは後で見る
  result="$(xcrun notarytool submit "$submission" \
    --key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" \
    --wait --timeout 20m --output-format json)" || rc=$?
  submission_id="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)"
  echo "提出 ID: ${submission_id:-不明} / 結果: ${status:-不明}（notarytool の終了コード $rc）"
  if ((rc != 0)) || [[ "$status" != "Accepted" ]]; then
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" \
        --key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" >&2 || true
    fi
    echo "公証に通りませんでした。上のログの issues を確認してください。" >&2
    exit 1
  fi
}

echo "==> プロジェクトを生成"
xcodegen generate --spec Apps/macOS/project.yml --quiet
scripts/check-release-config.sh

echo "==> アーカイブ（Release、Developer ID で手動署名）"
xcodebuild \
  -project Apps/macOS/Utter.xcodeproj \
  -scheme UtterMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  DEVELOPMENT_TEAM="$UTTER_TEAM_ID" \
  UTTER_BUNDLE_ID_PREFIX="$UTTER_BUNDLE_ID_PREFIX" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$signing_identity" \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$UTTER_BUILD_NUMBER" \
  -quiet archive

echo "==> 書き出し（developer-id）"
export_options="$out_dir/ExportOptions.plist"
cat >"$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>$signing_identity</string>
  <key>teamID</key>
  <string>$UTTER_TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportPath "$export_dir" \
  -exportOptionsPlist "$export_options" \
  -quiet
if [[ ! -d "$app" ]]; then
  echo "書き出したアプリが見つかりません: $app" >&2
  exit 1
fi

echo "==> 署名を確認（Developer ID・Hardened Runtime・secure timestamp・Entitlement）"
codesign --verify --deep --strict "$app"
signature_info="$(codesign -dvv "$app" 2>&1)"
if ! grep -q "^Authority=Developer ID Application: .*($UTTER_TEAM_ID)$" <<<"$signature_info"; then
  echo "Developer ID Application（Team ID $UTTER_TEAM_ID）で署名されていません。" >&2
  exit 1
fi
if ! grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$signature_info"; then
  echo "Hardened Runtime が有効になっていません。" >&2
  exit 1
fi
if ! grep -q '^Timestamp=' <<<"$signature_info"; then
  echo "署名に secure timestamp がありません。" >&2
  exit 1
fi
info_plist="$app/Contents/Info.plist"
signed_entitlements="$out_dir/signed.entitlements"
# Entitlement がない署名ではファイルが作られないため、そのときは「どれも無効」として扱う
codesign -d --entitlements "$signed_entitlements" --xml "$app" 2>/dev/null || true
signed_entitlement_enabled() {
  [[ -f "$signed_entitlements" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$1" "$signed_entitlements" 2>/dev/null)" == "true" ]]
}
# 開発用の get-task-allow が残っていると公証に通らない（書き出しで外れるはず。早めに分かりやすく失敗させる）
if signed_entitlement_enabled com.apple.security.get-task-allow; then
  echo "署名に com.apple.security.get-task-allow が残っています（公証に通らない）。" >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$info_plist" >/dev/null 2>&1 &&
  ! signed_entitlement_enabled com.apple.security.device.audio-input; then
  echo "マイクの用途説明があるのに、署名に com.apple.security.device.audio-input がありません。" >&2
  exit 1
fi

echo "==> アプリを公証して staple"
notarize_zip="$out_dir/notarize-app.zip"
ditto -c -k --keepParent "$app" "$notarize_zip"
notarize "$notarize_zip"
rm -f "$notarize_zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

echo "==> zip を作成"
ditto -c -k --keepParent "$app" "$out_dir/$zip_name"

echo "==> dmg を作成して署名・公証・staple"
dmg_root="$out_dir/dmg"
mkdir -p "$dmg_root"
ditto "$app" "$dmg_root/utter.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create -volname utter -srcfolder "$dmg_root" -fs HFS+ -format UDZO -ov -quiet "$out_dir/$dmg_name"
rm -rf "$dmg_root"
codesign --sign "$signing_identity" --timestamp "$out_dir/$dmg_name"
notarize "$out_dir/$dmg_name"
xcrun stapler staple "$out_dir/$dmg_name"
xcrun stapler validate "$out_dir/$dmg_name"
spctl --assess --type open --context context:primary-signature --verbose=2 "$out_dir/$dmg_name"

echo "==> SHA-256"
(cd "$out_dir" && shasum -a 256 "$zip_name" "$dmg_name" >SHA256SUMS.txt && cat SHA256SUMS.txt)

echo "完了: $out_dir/$zip_name, $out_dir/$dmg_name, $out_dir/SHA256SUMS.txt"
