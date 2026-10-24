#!/usr/bin/env bash
# 品質チェック: format lint → ログ出力の検査 → Swift Package の build/test → アプリの署名なしビルド
#   → iOS 最低バージョンの一致 → iOS Simulator 向けの署名なしビルド（Package と Apps/iOS）→ シェルスクリプト lint
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
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO \
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

echo "==> iOS の最低バージョンの一致（Package.swift と Apps/iOS/project.yml）"
# 仮置きの値（#54 で確定）を変えるときに、片方だけ直して食い違わないようにする
ios_app_target="$(sed -nE 's/^[[:space:]]*iOS:[[:space:]]*"?([0-9]+)(\.0)?"?[[:space:]]*$/\1/p' Apps/iOS/project.yml)"
if [[ -z "$ios_app_target" ]]; then
  echo "Apps/iOS/project.yml から iOS の deploymentTarget を読み取れません。" >&2
  exit 1
fi
ios_packages=()
for manifest in "${packages[@]}"; do
  package_ios="$(sed -nE 's/.*\.iOS\(\.v([0-9]+)\).*/\1/p' "$manifest")"
  [[ -z "$package_ios" ]] && continue
  ios_packages+=("$(dirname -- "$manifest")")
  if [[ "$package_ios" != "$ios_app_target" ]]; then
    echo "${manifest} の iOS 最低バージョン（${package_ios}）が Apps/iOS/project.yml（${ios_app_target}）と一致しません。" >&2
    exit 1
  fi
done
echo "iOS ${ios_app_target}（Apps/iOS と ${#ios_packages[@]} Package）"

echo "==> iOS Simulator 向けの署名なしビルド（Package と Apps/iOS）"
if ! xcodebuild -showsdks 2>/dev/null | grep -q -- '-sdk iphonesimulator'; then
  # CI（macos-26 ランナー）には iOS Simulator SDK があるため、CI で無いのは異常として落とす
  if [[ "${CI:-}" == "true" ]]; then
    echo "iOS Simulator SDK が見つかりません（CI では必須）。" >&2
    exit 1
  fi
  echo "iOS Simulator SDK が見つからないためスキップします（Xcode > Settings > Components で iOS を導入してください）。"
else
  ios_derived_data="build/DerivedData-iOS"
  for package_dir in ${ios_packages[@]+"${ios_packages[@]}"}; do
    echo "--> ${package_dir}（iOS Simulator）"
    # Package のディレクトリで実行すると、Package 名のスキームが自動で作られる
    (cd "$package_dir" && xcodebuild \
      -scheme "$(basename -- "$package_dir")" \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$repo_root/$ios_derived_data/Packages" \
      CODE_SIGNING_ALLOWED=NO \
      -quiet build)
  done
  echo "--> Apps/iOS"
  xcodegen generate --spec Apps/iOS/project.yml --quiet
  xcodebuild \
    -project Apps/iOS/Utter.xcodeproj \
    -scheme UtteriOS \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$ios_derived_data/App" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO \
    -quiet build
  ios_info_plist="$ios_derived_data/App/Build/Products/Debug-iphonesimulator/utter.app/Info.plist"
  if [[ ! -f "$ios_info_plist" ]]; then
    echo "iOS アプリのビルド成果物が見つかりません: $ios_info_plist" >&2
    exit 1
  fi
fi

echo "==> shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # Verification/ の計測スクリプトも対象にする（Swift のビルドは verify に含めない。各 README を参照）
  shell_scripts=(scripts/*.sh Verification/*/scripts/*.sh)
  shellcheck "${shell_scripts[@]}"
else
  echo "shellcheck が見つからないためスキップします（brew install shellcheck）。"
fi

echo "すべての品質チェックに成功しました。"
