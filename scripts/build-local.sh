#!/usr/bin/env bash
# 自前ビルド（AC-13）: 開発者（maintainer）の秘密情報なしで、各自の Apple ID の開発用署名（Apple Development）で
# macOS アプリをビルドする。Team ID と Bundle ID の接頭辞は Config/Local.xcconfig（gitignore 済み）から読む。
# 同じ Local.xcconfig・同じ証明書でビルドし続ければ、Accessibility・マイク等の許可（TCC）は再ビルドで外れない
# （docs/ビルド・配布規約.md「自前ビルド（固定の開発用署名）」）。
#
# 使い方: scripts/build-local.sh [-c Release|Debug]
#   既定は Release（配布物と同じ Hardened Runtime。Debug はデバッガ接続用）。
#   成果物は build/local/DerivedData/Build/Products/<構成>/utter.app
set -euo pipefail

usage() {
  echo "使い方: scripts/build-local.sh [-c Release|Debug]" >&2
}

configuration="Release"
while (($# > 0)); do
  case "$1" in
    -c | --configuration)
      if (($# < 2)); then
        usage
        exit 2
      fi
      configuration="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
if [[ "$configuration" != "Release" && "$configuration" != "Debug" ]]; then
  echo "構成は Release か Debug を指定してください: $configuration" >&2
  exit 2
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

local_xcconfig="Config/Local.xcconfig"
if [[ ! -f "$local_xcconfig" ]]; then
  echo "$local_xcconfig がありません。雛形をコピーし、自分の Team ID と Bundle ID の接頭辞を書いてください:" >&2
  echo "  cp Config/Local.xcconfig.example $local_xcconfig" >&2
  exit 1
fi

# xcconfig の「KEY = value」の最後の定義を読む（// 以降のコメントと前後の空白を除く）
xcconfig_value() {
  sed -n "s|^[[:space:]]*$1[[:space:]]*=[[:space:]]*||p" "$local_xcconfig" |
    sed -e 's|//.*$||' -e 's/[[:space:]]*$//' | tail -n 1
}

team_id="$(xcconfig_value DEVELOPMENT_TEAM)"
bundle_prefix="$(xcconfig_value UTTER_BUNDLE_ID_PREFIX)"
if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ || "$team_id" == "XXXXXXXXXX" ]]; then
  echo "$local_xcconfig の DEVELOPMENT_TEAM に自分の Team ID（英大文字・数字10桁）を書いてください。" >&2
  echo "Team ID は Xcode > Settings > Accounts で Apple ID を追加すると確認できます（無料の Personal Team でよい）。" >&2
  exit 1
fi
if [[ -z "$bundle_prefix" || "$bundle_prefix" == "com.example.yourname.utter" || "$bundle_prefix" == "invalid.utter" ]]; then
  echo "$local_xcconfig の UTTER_BUNDLE_ID_PREFIX に、他人と重ならない逆ドメインを書いてください（例: io.github.<GitHub ユーザー名>.utter）。" >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen が見つかりません。brew install xcodegen で導入してください。" >&2
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "xcodebuild を実行できません。Xcode を導入し、xcode-select か DEVELOPER_DIR で Xcode を指定してください。" >&2
  exit 1
fi

derived_data="build/local/DerivedData"
echo "==> プロジェクトを生成"
xcodegen generate --spec Apps/macOS/project.yml --quiet

echo "==> $configuration 構成を開発用署名でビルド（Team ID: ${team_id}）"
# 自動署名。Xcode に Apple ID を追加してあれば、開発用証明書とプロファイルを必要に応じて作る
xcodebuild \
  -project Apps/macOS/Utter.xcodeproj \
  -scheme UtterMac \
  -configuration "$configuration" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  -allowProvisioningUpdates \
  -quiet build

app="$derived_data/Build/Products/$configuration/utter.app"
if [[ ! -d "$app" ]]; then
  echo "ビルド成果物が見つかりません: $app" >&2
  exit 1
fi

echo "==> 署名を確認"
codesign --verify --strict "$app"
signature_info="$(codesign -dvv "$app" 2>&1)"
if grep -q '^Signature=adhoc' <<<"$signature_info"; then
  echo "Ad Hoc 署名になっています。再ビルドのたびに許可（TCC）が外れるため使いません。" >&2
  echo "Xcode > Settings > Accounts に Team ID $team_id の Apple ID を追加してから、もう一度実行してください。" >&2
  exit 1
fi
authority="$(sed -n 's/^Authority=//p' <<<"$signature_info" | head -n 1)"
echo "署名: $authority"
echo "designated requirement（同じ値なら再ビルドしても許可は外れない）:"
codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => /  /p'

echo "完了: $app"
echo "起動: open \"$app\""
