#!/usr/bin/env bash
# 記録済みの .trace から OSSignpostIntervals 表を書き出し、区間ごとの p50/p95 を集計する（#52）。
#
# 使い方:
#   summarize-signposts.sh TRACE [--process NAME] [--subsystem utter.perf]
#
# 出力（TRACE と同じディレクトリ）: NAME.intervals.xml、NAME.summary.md、NAME.durations.csv
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$script_dir/.."

if (($# < 1)) || [[ "$1" == -* ]]; then
  sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 64
fi
trace="${1%/}"
shift
if [[ ! -d "$trace" ]]; then
  echo "trace が見つかりません: $trace" >&2
  exit 66
fi

base="${trace%.trace}"
xml="$base.intervals.xml"
summary="$base.summary.md"
csv="$base.durations.csv"

echo "==> 書き出し: $xml"
xcrun xctrace export --input "$trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="OSSignpostIntervals"]' \
  --output "$xml"

echo "==> 集計ツールのビルド"
swift build --package-path "$package_dir" -c release --product perf-probe-summarize >/dev/null
bin_dir="$(swift build --package-path "$package_dir" -c release --show-bin-path)"

"$bin_dir/perf-probe-summarize" "$xml" --csv "$csv" "$@" | tee "$summary"
echo
echo "集計: $summary"
echo "区間ごとの所要時間: $csv"
