#!/usr/bin/env bash
# Signpost 区間を xctrace で記録し、終了後に p50/p95 を集計する（#52）。
#
# 使い方:
#   record-signposts.sh --label NAME --attach PID|プロセス名 [--time-limit 10m] [--output-dir DIR] [--process NAME]
#   record-signposts.sh --label NAME [--time-limit 10m] [--output-dir DIR] --launch -- コマンド [引数...]
#
# --attach は起動済みのアプリに接続する。記録中に人が操作を繰り返し、Ctrl-C か --time-limit で止める。
# 出力: DIR/NAME.trace（Instruments で開ける）、DIR/NAME.intervals.xml、DIR/NAME.summary.md、DIR/NAME.durations.csv
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output_dir="$script_dir/../out"
label=""
attach=""
time_limit=""
process_filter=""
launch=()

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

while (($# > 0)); do
  case "$1" in
    --label) label="${2:?}"; shift 2 ;;
    --attach) attach="${2:?}"; shift 2 ;;
    --time-limit) time_limit="${2:?}"; shift 2 ;;
    --output-dir) output_dir="${2:?}"; shift 2 ;;
    --process) process_filter="${2:?}"; shift 2 ;;
    --launch)
      shift
      [[ "${1:-}" == "--" ]] && shift
      launch=("$@")
      break
      ;;
    -h | --help) usage ;;
    *) echo "不明な引数: $1" >&2; usage ;;
  esac
done

[[ -n "$label" ]] || usage
if [[ -n "$attach" && ${#launch[@]} -gt 0 ]] || [[ -z "$attach" && ${#launch[@]} -eq 0 ]]; then
  echo "--attach と --launch のどちらか一方を指定してください。" >&2
  usage
fi
if ! xcrun --find xctrace >/dev/null 2>&1; then
  echo "xctrace が見つかりません。DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer を指定してください。" >&2
  exit 69
fi

mkdir -p "$output_dir"
trace="$output_dir/$label.trace"
if [[ -e "$trace" ]]; then
  echo "既に存在します: ${trace}（別の --label を指定してください）" >&2
  exit 73
fi

record=(xcrun xctrace record --instrument os_signpost --output "$trace")
if [[ -n "$time_limit" ]]; then
  record+=(--time-limit "$time_limit")
fi
if [[ -n "$attach" ]]; then
  record+=(--attach "$attach")
else
  record+=(--launch -- "${launch[@]}")
fi

echo "==> 記録: $trace"
# Ctrl-C で記録を止めても、後続の集計まで進める。
# trap '' だと子プロセス（xctrace）も SIGINT を無視してしまうため、何もしないハンドラを置く
trap ':' INT
"${record[@]}" || echo "xctrace が終了コード $? で終わりました。保存済みの trace を集計します。" >&2
trap - INT

summarize=("$script_dir/summarize-signposts.sh" "$trace")
if [[ -n "$process_filter" ]]; then
  summarize+=(--process "$process_filter")
fi
"${summarize[@]}"
