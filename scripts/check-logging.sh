#!/usr/bin/env bash
# ログの秘匿（iAC-10）: 製品コードに、値をそのまま標準出力・システムログへ出す呼び出しがないことを確かめる。
#
# print / debugPrint / dump / NSLog は OSLog と違い、文字列の補間を非公開（<private>）にしないため、
# 発話本文・API キー・トークンがそのままコンソールや sysdiagnose に残る。製品コードのログは OSLog を使う。
# OSLog（Logger / os_log）は補間を既定で非公開にするため、ここでは検査しない。
# `privacy: .public` は列挙値などの正当な用途が多く、機械的に区別できないため、レビューで確認する。
#
# 対象外:
# - テストコード（Packages/*/Tests/）
# - utter-eval（評価結果の表を標準出力に出すのが役割の開発用 CLI。発話音声・本文は扱わない）
#
# 引数でファイルを渡すと、そのファイルだけを検査する（このスクリプト自体の確認用）。
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if (($# > 0)); then
  sources="$(printf '%s\n' "$@")"
else
  sources="$(
    git ls-files --cached --others --exclude-standard -- \
      'Packages/*/Sources/*.swift' 'Apps/*.swift' 'Extensions/*.swift' 'Workers/*.swift' |
      grep -v '^Packages/UtterEvaluation/Sources/utter-eval/' || true
  )"
fi
if [[ -z "$sources" ]]; then
  echo "検査対象の Swift ソースがないためスキップします。"
  exit 0
fi

# 識別子の一部（fingerprint( など）やメソッド（.dump( など）には一致させない。Swift.print( は一致させる。
# 行頭の空白に続く // で始まる行（コメント）は除く
pattern='(^|[^A-Za-z0-9_.]|Swift\.)(print|debugPrint|dump|NSLog)[[:space:]]*\('
matches="$(
  printf '%s\n' "$sources" | tr '\n' '\0' | xargs -0 grep -nHE "$pattern" -- |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true
)"
if [[ -n "$matches" ]]; then
  echo "製品コードで print / debugPrint / dump / NSLog を使っています。OSLog の Logger を使ってください（iAC-10）:" >&2
  printf '%s\n' "$matches" >&2
  exit 1
fi
echo "print / debugPrint / dump / NSLog の使用はありません。"
