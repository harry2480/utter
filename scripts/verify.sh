#!/usr/bin/env bash
# 品質チェック: format lint → ログ出力の検査 → Swift Package の build/test → アプリの署名なしビルド・テスト → シェルスクリプト lint
# アプリターゲット（Apps/, Extensions/, Workers/）は xcodegen で生成し、署名なしの xcodebuild でビルドする。
# 新しいターゲットを作ったら「アプリの署名なしビルド・テスト」に追加する。
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

echo "==> アプリの署名なしビルド・テスト（xcodegen → xcodebuild）"
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
# アプリの純粋なロジックのユニットテスト（アプリは起動しない）
xcodebuild \
  -project Apps/macOS/Utter.xcodeproj \
  -scheme UtterMac \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO \
  -quiet test
# メニューバー常駐で Dock に出さない設定と、マイクの用途説明が入っていることを確かめる（アプリは起動しない）
mac_info_plist="$derived_data/Build/Products/Debug/utter.app/Contents/Info.plist"
if [[ ! -f "$mac_info_plist" ]]; then
  echo "macOS アプリのビルド成果物が見つかりません: $mac_info_plist" >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$mac_info_plist")" != "true" ]]; then
  echo "macOS アプリの Info.plist に LSUIElement = YES がありません。" >&2
  exit 1
fi
# マイクの用途説明がないと、録音を始めたときに OS がアプリを終了させる（PERM-01）
if ! /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$mac_info_plist" >/dev/null 2>&1; then
  echo "macOS アプリの Info.plist に NSMicrophoneUsageDescription がありません。" >&2
  exit 1
fi
# XPC STT Worker がアプリに組み込まれ、アプリ側が接続する名前（アプリの Bundle ID + .stt-worker）になっていることを確かめる
worker_info_plist="$derived_data/Build/Products/Debug/utter.app/Contents/XPCServices/UtterSTTWorker.xpc/Contents/Info.plist"
if [[ ! -f "$worker_info_plist" ]]; then
  echo "XPC STT Worker がアプリに組み込まれていません: $worker_info_plist" >&2
  exit 1
fi
mac_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$mac_info_plist")"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$worker_info_plist")" != "$mac_bundle_id.stt-worker" ]]; then
  echo "XPC STT Worker の Bundle ID が $mac_bundle_id.stt-worker ではありません。" >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :XPCService:ServiceType' "$worker_info_plist")" != "Application" ]]; then
  echo "XPC STT Worker の Info.plist に XPCService.ServiceType = Application がありません。" >&2
  exit 1
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
