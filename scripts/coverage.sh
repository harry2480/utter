#!/usr/bin/env bash
# Swift Package のテストをカバレッジ付きで実行し、Codecov 用の lcov を coverage/ に出力する。
# 出力: coverage/<Package>.lcov（Packages/ 配下のパッケージごと）
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

output_dir="$repo_root/coverage"
rm -rf "$output_dir"
mkdir -p "$output_dir"

shopt -s nullglob
packages=(Packages/*/Package.swift)
if (( ${#packages[@]} == 0 )); then
  echo "Packages/ にSwift Packageがないためスキップします。"
  exit 0
fi

llvm_cov="$(xcrun --find llvm-cov)"

for manifest in "${packages[@]}"; do
  package_dir="$(dirname -- "$manifest")"
  package_name="$(basename -- "$package_dir")"
  echo "--> $package_dir"

  swift test --package-path "$package_dir" --enable-code-coverage

  bin_path="$(swift build --package-path "$package_dir" --show-bin-path)"
  profdata="$(dirname -- "$(swift test --package-path "$package_dir" --show-codecov-path)")/default.profdata"
  if [[ ! -f "$profdata" ]]; then
    echo "カバレッジデータが見つかりません: $profdata" >&2
    exit 1
  fi

  # テストバイナリ（macOS では <Name>.xctest/Contents/MacOS/<Name>）
  test_binaries=()
  for bundle in "$bin_path"/*.xctest; do
    test_binaries+=("$bundle/Contents/MacOS/$(basename -- "$bundle" .xctest)")
  done
  if (( ${#test_binaries[@]} == 0 )); then
    echo "$package_dir にテストターゲットがないためスキップします。"
    continue
  fi

  object_args=()
  for binary in "${test_binaries[@]:1}"; do
    object_args+=(-object "$binary")
  done

  # テストコードと依存パッケージ（.build/checkouts）は計測対象から除外する
  "$llvm_cov" export \
    -format=lcov \
    -instr-profile "$profdata" \
    -ignore-filename-regex='(/Tests/|/\.build/)' \
    "${test_binaries[0]}" "${object_args[@]+"${object_args[@]}"}" \
    > "$output_dir/$package_name.lcov"

  echo "    $output_dir/$package_name.lcov"
done
