#!/usr/bin/env bash
# 品質チェック: format lint → ログ出力の検査 → Swift Package の build/test → アプリの署名なしビルド → Release の署名設定の検査 → シェルスクリプト lint → ワークフロー lint
# アプリターゲット（Apps/, Extensions/, Workers/）は xcodegen で生成し、署名なしの xcodebuild でビルドする。
# 新しいターゲットを作ったら「アプリの署名なしビルド」に追加する。
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

swift_sources="$(git ls-files --cached --others --exclude-standard -- '*.swift')"

echo "==> swift format lint"
if [[ -z "$swift_sources" ]]; then
  echo "Swiftソースがないためスキップします。"
else
  printf '%s\n' "$swift_sources" | xargs swift format lint --strict
fi

echo "==> ログ出力の検査（iAC-10）"
scripts/check-logging.sh

echo "==> Swift Package build / test"
shopt -s nullglob
packages=(Packages/*/Package.swift)
if (( ${#packages[@]} == 0 )); then
  echo "Packages/ にSwift Packageがないためスキップします。"
else
  for manifest in "${packages[@]}"; do
    package_dir="$(dirname -- "$manifest")"
    echo "--> $package_dir"
    swift build --package-path "$package_dir"
    swift test --package-path "$package_dir"
  done
fi

echo "==> アプリの署名なしビルド（xcodegen → xcodebuild）"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen が見つかりません。brew install xcodegen で導入してください。" >&2
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "xcodebuild を実行できません。Xcode を導入し、xcode-select か DEVELOPER_DIR で Xcode を指定してください" >&2
  echo "（例: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/verify.sh）。" >&2
  exit 1
fi
derived_data="build/DerivedData"
echo "--> Apps/macOS"
xcodegen generate --spec Apps/macOS/project.yml --quiet
xcodebuild \
  -project Apps/macOS/Utter.xcodeproj \
  -scheme UtterMac \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO \
  UTTER_SPARKLE_FEED_URL= UTTER_SPARKLE_PUBLIC_ED_KEY= \
  -quiet build
# メニューバー常駐で Dock に出さない設定が入っていることを確かめる（アプリは起動しない）
mac_info_plist="$derived_data/Build/Products/Debug/utter.app/Contents/Info.plist"
if [[ ! -f "$mac_info_plist" ]]; then
  echo "macOS アプリのビルド成果物が見つかりません: $mac_info_plist" >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$mac_info_plist")" != "true" ]]; then
  echo "macOS アプリの Info.plist に LSUIElement = YES がありません。" >&2
  exit 1
fi
# 自動更新（Sparkle）: URL と公開鍵を空にした（Local.xcconfig の値を上書きした）ビルドで、Info.plist に空のまま入り、アプリは Sparkle を起動しない。
# 低頻度の確認・システムプロファイルを送らない・自動インストールを選べないことも確かめる（Apps/macOS/Info.plist）
mac_plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$mac_info_plist" 2>/dev/null || echo "<なし>"
}
for key_and_expected in "SUFeedURL=" "SUPublicEDKey=" "SUScheduledCheckInterval=604800" \
  "SUEnableSystemProfiling=false" "SUAllowsAutomaticUpdates=false"; do
  key="${key_and_expected%%=*}"
  expected="${key_and_expected#*=}"
  if [[ "$(mac_plist_value "$key")" != "$expected" ]]; then
    echo "macOS アプリの Info.plist の $key が想定（${expected:-空}）と違います: $(mac_plist_value "$key")" >&2
    exit 1
  fi
done
# 同梱する Sparkle のライセンス表示が、取得した版の LICENSE と同じで、アプリに入っていること
sparkle_license="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/LICENSE"
bundled_license="$derived_data/Build/Products/Debug/utter.app/Contents/Resources/Licenses/Sparkle-LICENSE.txt"
if ! cmp -s "$sparkle_license" Apps/macOS/Licenses/Sparkle-LICENSE.txt; then
  echo "Apps/macOS/Licenses/Sparkle-LICENSE.txt が取得した Sparkle の LICENSE と違います。差し替えてください: $sparkle_license" >&2
  exit 1
fi
if [[ ! -f "$bundled_license" ]]; then
  echo "アプリに Sparkle のライセンス表示が入っていません: $bundled_license" >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$mac_info_plist" >/dev/null 2>&1; then
  echo "SUEnableAutomaticChecks は Info.plist に置かない（初回に Sparkle が利用者に確かめる）。" >&2
  exit 1
fi

echo "==> 配布用（Release）の署名設定の検査"
scripts/check-release-config.sh

echo "==> shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # Verification/ の計測スクリプトも対象にする（Swift のビルドは verify に含めない。各 README を参照）
  shell_scripts=(scripts/*.sh Verification/*/scripts/*.sh)
  shellcheck "${shell_scripts[@]}"
else
  echo "shellcheck が見つからないためスキップします（brew install shellcheck）。"
fi

echo "==> actionlint"
if command -v actionlint >/dev/null 2>&1; then
  # .github/workflows/*.yml の構文・式・run のシェル（shellcheck があれば併用）を検査する
  actionlint
else
  echo "actionlint が見つからないためスキップします（brew install actionlint）。"
fi

echo "すべての品質チェックに成功しました。"
