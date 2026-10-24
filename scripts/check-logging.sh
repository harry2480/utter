#!/usr/bin/env bash
# ログの秘匿（iAC-10）: 製品コードに、値をそのまま標準出力・標準エラー・システムログ・クラッシュ情報へ出す呼び出しがないことを確かめる。
#
# 検出するもの:
# - print / debugPrint / dump / NSLog / fputs / puts / fprintf と、FileHandle.standardOutput / standardError への書き込み。
#   OSLog と違い文字列の補間を非公開（<private>）にしないため、発話本文・API キー・トークンがそのままコンソールや
#   sysdiagnose に残る。呼び出し（print(x)）だけでなく関数参照（forEach(print) / map(dump)）も検出する
# - fatalError / precondition / preconditionFailure / assert / assertionFailure のメッセージでの文字列補間（\(…)）。
#   メッセージはクラッシュレポートに残るため、補間しない固定の文言にする（同じ行にある補間だけを検出する）
#
# 検出しないもの:
# - OSLog（Logger / os_log）。補間を既定で非公開にするため。`privacy: .public` は列挙値などの正当な用途が多く、
#   機械的に区別できないため、レビューで確認する
# - テストコード（Packages/*/Tests/）
#
# 既知の誤検知: 文字列リテラルの中（"print(" など）と、行末コメントの中の一致は検出してしまう。
# 行全体がコメントの行（// /// /* * で始まる行）は除く。
#
# 意図して標準出力などへ出す行は、その行か直前の行に `check-logging: allow` と理由を書いて除外する
# （例: 本文を含む評価結果を読み、標準出力には集計表だけを出す utter-eval）。
#
# 引数でファイルを渡すと、そのファイルだけを検査する（このスクリプト自体の確認用）。
set -euo pipefail

files=()
if (($# > 0)); then
  for file in "$@"; do
    if [[ ! -f "$file" ]]; then
      echo "ファイルがありません: $file" >&2
      exit 2
    fi
    files+=("$(cd -- "$(dirname -- "$file")" && pwd)/$(basename -- "$file")")
  done
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ((${#files[@]} == 0)); then
  while IFS= read -r file; do
    files+=("$file")
  done < <(
    git ls-files --cached --others --exclude-standard -- \
      'Packages/*/Sources/*.swift' 'Apps/*.swift' 'Extensions/*.swift' 'Workers/*.swift'
  )
fi
if ((${#files[@]} == 0)); then
  echo "検査対象の Swift ソースがないためスキップします。"
  exit 0
fi

# 前の境界: 識別子の一部（fingerprint / myNSLog）・メソッド（x.dump）・別名の修飾（MySwift.print）には一致させない。
# モジュール名で修飾した呼び出し（Swift.print / Foundation.NSLog）は一致させる。
# 後ろの区切り: 呼び出しの ( と、関数参照として渡すときの ) , に一致させる
before='(^|[^A-Za-z0-9_.]|(^|[^A-Za-z0-9_.])(Swift|Foundation|Darwin|Glibc)\.)'
output_pattern="${before}(print|debugPrint|dump|NSLog|fputs|puts|fprintf)[[:space:]]*[(),]|FileHandle\\.standard(Output|Error)"
crash_pattern="${before}(fatalError|precondition|preconditionFailure|assert|assertionFailure)[[:space:]]*\\(.*\\\\\\("

matches="$(
  # -v で渡すとエスケープが解釈されるため、環境変数で渡す
  OUTPUT_PATTERN="$output_pattern" CRASH_PATTERN="$crash_pattern" awk '
    BEGIN { output = ENVIRON["OUTPUT_PATTERN"]; crash = ENVIRON["CRASH_PATTERN"] }
    FNR == 1 { previous = "" }
    {
      line = $0
      comment = line ~ /^[[:space:]]*(\/\/|\/\*|\*)/
      allowed = line ~ /check-logging: allow/ || previous ~ /check-logging: allow/
      if (!comment && !allowed && (line ~ output || line ~ crash)) {
        print FILENAME ":" FNR ":" line
      }
      previous = line
    }
  ' "${files[@]}"
)"
if [[ -n "$matches" ]]; then
  echo "製品コードで、値をそのまま出力する呼び出し、またはクラッシュメッセージの補間があります。" >&2
  echo "ログは OSLog の Logger を使い、クラッシュメッセージは固定の文言にしてください（iAC-10）:" >&2
  printf '%s\n' "$matches" >&2
  exit 1
fi
echo "値をそのまま出力する呼び出しと、クラッシュメッセージの補間はありません。"
