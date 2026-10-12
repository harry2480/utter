#!/usr/bin/env bash
set -euo pipefail

max_iterations="${LOOP_MAX_ITERATIONS:-5}"
interval_seconds="${LOOP_INTERVAL_SECONDS:-10}"

if [[ ! "$max_iterations" =~ ^[1-9][0-9]*$ ]] || (( max_iterations > 20 )); then
  echo "LOOP_MAX_ITERATIONSには1から20までの整数を指定してください。" >&2
  exit 2
fi

if [[ ! "$interval_seconds" =~ ^[0-9]+$ ]] || (( interval_seconds > 3600 )); then
  echo "LOOP_INTERVAL_SECONDSには0から3600までの整数を指定してください。" >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for ((iteration = 1; iteration <= max_iterations; iteration++)); do
  echo "Loop実行 ${iteration}/${max_iterations}"
  if output="$("$script_dir/loop-once.sh")"; then
    status=0
  else
    status=$?
  fi
  printf '%s\n' "$output"

  if (( status != 0 )); then
    exit "$status"
  fi

  if printf '%s\n' "$output" | grep -Fxq 'LOOP_IDLE'; then
    echo "対象作業がありません。"
    exit 0
  fi

  if (( iteration < max_iterations && interval_seconds > 0 )); then
    sleep "$interval_seconds"
  fi
done

echo "${max_iterations}回実行したため停止しました。"
