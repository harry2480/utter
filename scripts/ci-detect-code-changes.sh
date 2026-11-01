#!/usr/bin/env bash
# CI で、文書（docs/**・*.md）以外の変更があるかを判定し、GITHUB_OUTPUT に code=true|false を書く（#234）。
# 差分の基準を決められないとき（新しいブランチの最初の push など）は、安全側に code=true とする。
#
# 環境変数:
#   EVENT_NAME   github.event_name（pull_request / push）
#   PR_BASE / PR_HEAD       pull_request のときの base と head のコミット
#   PUSH_BEFORE / PUSH_AFTER push のときの前後のコミット
set -euo pipefail

output="${GITHUB_OUTPUT:-/dev/stdout}"
zero_sha="0000000000000000000000000000000000000000"

case "${EVENT_NAME:-}" in
  pull_request)
    base="${PR_BASE:-}"
    head="${PR_HEAD:-}"
    ;;
  push)
    base="${PUSH_BEFORE:-}"
    head="${PUSH_AFTER:-}"
    ;;
  *)
    base=""
    head=""
    ;;
esac

if [[ -z "$base" || -z "$head" || "$base" == "$zero_sha" ]] \
  || ! git cat-file -e "${base}^{commit}" 2>/dev/null \
  || ! git cat-file -e "${head}^{commit}" 2>/dev/null; then
  echo "差分の基準を決められないため、検証する"
  echo "code=true" >>"$output"
  exit 0
fi

# pull_request は base からの分岐点との差分（base 側の新しいコミットを含めない）
if [[ "$EVENT_NAME" == pull_request ]]; then
  base="$(git merge-base "$base" "$head")"
fi

changed="$(git -c core.quotePath=false diff --name-only "$base" "$head")"
code_files="$(grep -vE '^docs/|\.md$' <<<"$changed" || true)"

if [[ -z "$changed" ]]; then
  echo "変更なし。検証する"
  echo "code=true" >>"$output"
elif [[ -n "$code_files" ]]; then
  echo "文書以外の変更がある:"
  printf '  %s\n' "$code_files"
  echo "code=true" >>"$output"
else
  echo "文書だけの変更のため、検証を飛ばす"
  echo "code=false" >>"$output"
fi
