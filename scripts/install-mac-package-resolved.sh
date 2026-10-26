#!/usr/bin/env bash
# コミットした Apps/macOS/Package.resolved を、xcodegen が生成した Utter.xcodeproj の中へ写す。
# Xcode のプロジェクトでは Package.resolved が生成物（gitignore 済みの *.xcodeproj）の中に置かれるため、
# 依存の版を固定するファイル（docs/ビルド・配布規約.md「依存」）をプロジェクトの外に置き、生成のたびに写す。
# Apps/macOS/project.yml の postGenCommand から呼ばれる（xcodegen generate のあとに自動で動く）。
#
# 依存の版を変えたとき: Apps/macOS/Specs/Sparkle.yml を直して xcodegen generate → xcodebuild -resolvePackageDependencies で
# 中の Package.resolved を更新し、scripts/install-mac-package-resolved.sh --update で Apps/macOS/ へ書き戻してコミットする。
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
committed="$repo_root/Apps/macOS/Package.resolved"
in_project="$repo_root/Apps/macOS/Utter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [[ "${1:-}" == "--update" ]]; then
  if [[ ! -f "$in_project" ]]; then
    echo "$in_project がありません。先に xcodebuild -resolvePackageDependencies を実行してください。" >&2
    exit 1
  fi
  cp "$in_project" "$committed"
  echo "Apps/macOS/Package.resolved を更新しました。"
  exit 0
fi

if [[ ! -f "$committed" ]]; then
  echo "Apps/macOS/Package.resolved がありません。" >&2
  exit 1
fi
mkdir -p "$(dirname -- "$in_project")"
cp "$committed" "$in_project"
