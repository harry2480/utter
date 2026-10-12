#!/usr/bin/env bash
set -euo pipefail

if ! command -v claude >/dev/null 2>&1; then
  echo "Loopの実行にはClaude Code CLIが必要です。" >&2
  exit 127
fi

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "Loopを実行する前に、このリポジトリへアクセスできるGitHub CLIで認証してください。" >&2
  exit 1
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "gitリポジトリ内からこのスクリプトを実行してください。" >&2
  exit 1
fi

max_turns="${LOOP_MAX_TURNS:-30}"
if [[ ! "$max_turns" =~ ^[1-9][0-9]*$ ]] || (( max_turns > 100 )); then
  echo "LOOP_MAX_TURNSには1から100までの整数を指定してください。" >&2
  exit 2
fi

claude --print --max-turns "$max_turns" "/loop-once"
