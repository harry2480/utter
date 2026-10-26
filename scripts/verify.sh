#!/usr/bin/env bash
# 品質チェック: format lint → ログ出力の検査 → Swift Package の build/test → アプリの署名なしビルド・テスト → Release の署名設定の検査
#   → iOS 最低バージョンの一致 → iOS Simulator 向けの署名なしビルド（Package と Apps/iOS・キーボード拡張）→ シェルスクリプト lint → ワークフロー lint
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
# Apps/*/*/Package.swift はアプリのうち OS の API を使わずにテストできる部分（Apps/iOS/UtteriOSKit）
packages=(Packages/*/Package.swift Apps/*/*/Package.swift)
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
  -disableAutomaticPackageResolution \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO \
  UTTER_SPARKLE_FEED_URL= UTTER_SPARKLE_PUBLIC_ED_KEY= \
  -quiet build
# アプリの純粋なロジックのユニットテスト（アプリは起動しない）
xcodebuild \
  -project Apps/macOS/Utter.xcodeproj \
  -scheme UtterMac \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO \
  UTTER_SPARKLE_FEED_URL= UTTER_SPARKLE_PUBLIC_ED_KEY= \
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

echo "==> iOS の最低バージョンの一致（Package.swift と Apps/iOS/project.yml）"
# 仮置きの値（#54 で確定）を変えるときに、片方だけ直して食い違わないようにする。
# 版数は「メジャー.マイナー」にそろえて比べる（project.yml の "26.0" / "18.4"、Package.swift の .v26 / .v18_4 / "18.4"）
normalize_version() {
  local major="${1%%.*}" minor="0"
  [[ "$1" == *.* ]] && minor="${1#*.}"
  echo "${major}.${minor%%.*}"
}
ios_app_lines="$(sed -nE 's/^[[:space:]]*iOS:[[:space:]]*"?([0-9]+(\.[0-9]+)*)"?[[:space:]]*$/\1/p' Apps/iOS/project.yml)"
if [[ -z "$ios_app_lines" || "$ios_app_lines" == *$'\n'* ]]; then
  echo "Apps/iOS/project.yml から iOS の deploymentTarget を1つに読み取れません（options.deploymentTarget だけに書き、ターゲット側で上書きしない）。" >&2
  exit 1
fi
ios_app_target="$(normalize_version "$ios_app_lines")"
ios_packages=()
for manifest in ${packages[@]+"${packages[@]}"}; do
  # コメント行を除いて、iOS を宣言しているかと版数を読み取れたかを分けて判定する（読めない形は黙って外さない）
  manifest_code="$(grep -vE '^[[:space:]]*//' "$manifest")"
  grep -q '\.iOS(' <<<"$manifest_code" || continue
  package_ios_values="$(sed -nE -e 's/.*\.iOS\(\.v([0-9]+(_[0-9]+)*)\).*/\1/p' -e 's/.*\.iOS\("([0-9]+(\.[0-9]+)*)"\).*/\1/p' <<<"$manifest_code" | tr '_' '.' | sort -u)"
  if [[ -z "$package_ios_values" || "$package_ios_values" == *$'\n'* ]]; then
    echo "${manifest} の iOS 最低バージョンを1つに読み取れません（.iOS(.vNN) / .iOS(.vNN_M) / .iOS(\"NN.M\") の形で1か所に書く）。" >&2
    exit 1
  fi
  package_ios="$(normalize_version "$package_ios_values")"
  ios_packages+=("$(dirname -- "$manifest")")
  if [[ "$package_ios" != "$ios_app_target" ]]; then
    echo "${manifest} の iOS 最低バージョン（${package_ios}）が Apps/iOS/project.yml（${ios_app_target}）と一致しません。" >&2
    exit 1
  fi
done
echo "iOS ${ios_app_target}（Apps/iOS と ${#ios_packages[@]} Package）"

echo "==> iOS Simulator 向けの署名なしビルド（Package と Apps/iOS・キーボード拡張）"
available_sdks="$(xcodebuild -showsdks 2>/dev/null || true)"
if ! grep -q -- '-sdk iphonesimulator' <<<"$available_sdks"; then
  # CI（macos-26 ランナー）には iOS Simulator SDK があるため、CI で無いのは異常として落とす
  if [[ "${CI:-}" == "true" ]]; then
    echo "iOS Simulator SDK が見つかりません（CI では必須）。" >&2
    exit 1
  fi
  echo "iOS Simulator SDK が見つからないためスキップします（Xcode > Settings > Components で iOS を導入してください）。"
else
  # Package 用と App 用で DerivedData を分ける（Package ごとに作られるワークスペースと App のプロジェクトで、ビルド設定のキャッシュを混ぜない）
  ios_derived_data="$repo_root/build/DerivedData-iOS"
  for package_dir in ${ios_packages[@]+"${ios_packages[@]}"}; do
    echo "--> ${package_dir}（iOS Simulator）"
    # Package のディレクトリで実行すると、Package 名のスキームが自動で作られる
    (cd "$package_dir" && xcodebuild \
      -scheme "$(basename -- "$package_dir")" \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$ios_derived_data/Packages" \
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
    UTTER_APP_GROUP_ENABLED=NO UTTER_HOST_APP_URL_SCHEME= \
    -quiet build
  ios_info_plist="$ios_derived_data/App/Build/Products/Debug-iphonesimulator/utter.app/Info.plist"
  if [[ ! -f "$ios_info_plist" ]]; then
    echo "iOS アプリのビルド成果物が見つかりません: $ios_info_plist" >&2
    exit 1
  fi
  # ビルド結果の最低バージョンも、上で確かめた値と同じであること（ターゲット側の上書きを検出する）
  ios_built_minimum="$(normalize_version "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$ios_info_plist")")"
  if [[ "$ios_built_minimum" != "$ios_app_target" ]]; then
    echo "iOS アプリの MinimumOSVersion（${ios_built_minimum}）が ${ios_app_target} と一致しません。" >&2
    exit 1
  fi
  plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
  # 本体アプリも App Group（#56 の判定待ち）は既定で無効。既定のビルドでは App Group ID を持たず、
  # 共有結果・本体アプリの状態を App Group に書かない
  # Info.plist の結線が壊れていないこと（キーがあること）も確かめる
  if ! /usr/libexec/PlistBuddy -c 'Print :UtterAppGroupIdentifier' "$ios_info_plist" >/dev/null 2>&1; then
    echo "iOS アプリの Info.plist に UtterAppGroupIdentifier がありません。" >&2
    exit 1
  fi
  if [[ -n "$(plist_value "$ios_info_plist" UtterAppGroupIdentifier)" ]]; then
    echo "既定のビルドで iOS アプリに App Group ID が入っています（Config/Local.xcconfig で有効にしたときだけ入れる）。" >&2
    exit 1
  fi
  # キーボード拡張（Extensions/iOSKeyboard）は本体アプリに埋め込まれてビルドされる
  keyboard_appex="$ios_derived_data/App/Build/Products/Debug-iphonesimulator/utter.app/PlugIns/UtterKeyboard.appex"
  keyboard_info_plist="$keyboard_appex/Info.plist"
  if [[ ! -f "$keyboard_info_plist" ]]; then
    echo "キーボード拡張のビルド成果物が見つかりません: $keyboard_info_plist" >&2
    exit 1
  fi
  if [[ "$(plist_value "$keyboard_info_plist" NSExtension:NSExtensionPointIdentifier)" != "com.apple.keyboard-service" ]]; then
    echo "キーボード拡張の NSExtensionPointIdentifier が com.apple.keyboard-service ではありません。" >&2
    exit 1
  fi
  if [[ "$(normalize_version "$(plist_value "$keyboard_info_plist" MinimumOSVersion)")" != "$ios_app_target" ]]; then
    echo "キーボード拡張の MinimumOSVersion が ${ios_app_target} と一致しません。" >&2
    exit 1
  fi
  # App Group（#56 の判定待ち）は既定で無効。既定のビルドではフルアクセスを要求せず、App Group ID も持たない
  # （上のビルドは Local.xcconfig で有効にした開発機でも既定値に固定している）
  if [[ "$(plist_value "$keyboard_info_plist" NSExtension:NSExtensionAttributes:RequestsOpenAccess)" != "false" ]]; then
    echo "既定のビルドでキーボード拡張の RequestsOpenAccess が false ではありません（App Group を有効にしたときだけ true）。" >&2
    exit 1
  fi
  if [[ -n "$(plist_value "$keyboard_info_plist" UtterAppGroupID)" ]]; then
    echo "既定のビルドでキーボード拡張に App Group ID が入っています（Config/Local.xcconfig で有効にしたときだけ入れる）。" >&2
    exit 1
  fi
  # キーボード拡張は UtterCore と UtterPersistence だけに依存する（iAC-08: STT・クラウド AI を持たない）。
  # Swift のシンボルに UtterSpeech / UtterAI のモジュール名が出ないことを確かめる
  for binary in "$keyboard_appex"/*; do
    [[ -f "$binary" && "$(file -b "$binary")" == *Mach-O* ]] || continue
    # grep -q が先に終わると nm が SIGPIPE になり pipefail で見逃すため、出力を受け取ってから調べる
    # モジュールの先頭として現れる形（$s11UtterSpeech / $s7UtterAI）だけを見る（UtterAIProviderID などに一致させない）
    if grep -qE '[$]s(11UtterSpeech|7UtterAI)' <<<"$(nm "$binary" 2>/dev/null || true)"; then
      echo "キーボード拡張に UtterSpeech / UtterAI がリンクされています: $binary" >&2
      exit 1
    fi
  done
fi

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
