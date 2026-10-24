#!/usr/bin/env bash
# 指定プロセスのメモリ（Physical footprint）と CPU 使用率を一定間隔で CSV に記録する（#52）。
#
# 使い方:
#   sample-process.sh (--pid PID | --name プロセス名)... [--interval 秒] [--duration 秒] [--output CSV]
#
#   --pid / --name  複数指定できる（例: アプリ本体と XPC STT Worker）。--name は完全一致（pgrep -x）
#   --interval      サンプリング間隔（既定 60 秒）。待機時 CPU を見るときは 60 秒以上を推奨
#   --duration      記録する時間（既定 300 秒）。0 なら Ctrl-C まで
#   --output        出力先（既定 out/sample-<日時>.csv）
#
# 列: timestamp, elapsed_s, pid, name, footprint_mb, footprint_peak_mb, rss_mb, cpu_time_s, cpu_percent
#   footprint_mb      vmmap --summary の Physical footprint（Activity Monitor の「メモリ」と同じ指標）
#   cpu_percent       直前のサンプルからの CPU 時間の増分 ÷ 経過時間（1コア = 100%）。最初の行は空
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
interval=60
duration=300
output=""
pids=()

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

while (($# > 0)); do
  case "$1" in
    --pid) pids+=("${2:?}"); shift 2 ;;
    --name)
      found="$(pgrep -x "${2:?}" || true)"
      if [[ -z "$found" ]]; then
        echo "プロセスが見つかりません: $2" >&2
        exit 66
      fi
      while IFS= read -r pid; do pids+=("$pid"); done <<<"$found"
      shift 2
      ;;
    --interval) interval="${2:?}"; shift 2 ;;
    --duration) duration="${2:?}"; shift 2 ;;
    --output) output="${2:?}"; shift 2 ;;
    -h | --help) usage ;;
    *) echo "不明な引数: $1" >&2; usage ;;
  esac
done

((${#pids[@]} > 0)) || usage
if ! [[ "$interval" =~ ^[0-9]+$ ]] || ((interval == 0)); then
  echo "--interval は正の整数（秒）" >&2
  exit 64
fi
[[ "$duration" =~ ^[0-9]+$ ]] || { echo "--duration は整数（秒）" >&2; exit 64; }
if [[ -z "$output" ]]; then
  mkdir -p "$script_dir/../out"
  output="$script_dir/../out/sample-$(date '+%Y%m%d-%H%M%S').csv"
fi

now() {
  perl -MTime::HiRes -e 'printf "%.3f\n", Time::HiRes::time()'
}

# vmmap の "Physical footprint:  12.3M" 形式（K/M/G）を MB にする
to_mb() {
  awk -v value="$1" 'BEGIN {
    unit = substr(value, length(value)); number = substr(value, 1, length(value) - 1) + 0
    if (unit == "K") number /= 1024; else if (unit == "G") number *= 1024
    else if (unit != "M") { number = value / 1048576 }
    printf "%.1f", number
  }'
}

# ps の CPU 時間（[[時:]分:]秒.xx、分は 60 を超えることがある）を秒にする
to_seconds() {
  awk -v value="$1" 'BEGIN {
    n = split(value, parts, ":"); total = 0
    for (i = 1; i <= n; i++) total = total * 60 + parts[i]
    printf "%.2f", total
  }'
}

# macOS 標準の bash 3.2 で動くよう、連想配列を使わず pids と同じ添字の配列で状態を持つ
last_cpu=()
last_time=()
first_cpu=()
first_time=()
max_footprint=()
names=()
alive=()
for i in "${!pids[@]}"; do alive[i]=1; done

echo "timestamp,elapsed_s,pid,name,footprint_mb,footprint_peak_mb,rss_mb,cpu_time_s,cpu_percent" >"$output"
echo "記録先: ${output}（Ctrl-C で終了）" >&2

start="$(now)"
stop=0
trap 'stop=1' INT TERM

while ((stop == 0)); do
  alive_count=0
  for i in "${!pids[@]}"; do
    ((alive[i] == 1)) || continue
    pid="${pids[i]}"
    ps_line="$(ps -o time=,rss=,comm= -p "$pid" 2>/dev/null || true)"
    if [[ -z "$ps_line" ]]; then
      echo "プロセスが終了しました: pid=$pid" >&2
      alive[i]=0
      continue
    fi
    alive_count=$((alive_count + 1))
    sample_time="$(now)"
    read -r cpu_raw rss_kb comm <<<"$ps_line"
    name="$(basename -- "$comm")"
    # CSV の列がずれないよう、プロセス名のカンマは空白にする
    name="${name//,/ }"
    names[i]="$name"
    cpu_seconds="$(to_seconds "$cpu_raw")"
    summary="$(vmmap --summary "$pid" 2>/dev/null || true)"
    footprint="$(awk '/^Physical footprint:/ { print $3 }' <<<"$summary")"
    footprint_peak="$(awk '/^Physical footprint \(peak\):/ { print $4 }' <<<"$summary")"
    footprint_mb=""
    footprint_peak_mb=""
    if [[ -n "$footprint" ]]; then footprint_mb="$(to_mb "$footprint")"; fi
    if [[ -n "$footprint_peak" ]]; then footprint_peak_mb="$(to_mb "$footprint_peak")"; fi
    rss_mb="$(awk -v kb="$rss_kb" 'BEGIN { printf "%.1f", kb / 1024 }')"

    cpu_percent=""
    if [[ -n "${last_cpu[i]:-}" ]]; then
      cpu_percent="$(awk -v c="$cpu_seconds" -v lc="${last_cpu[i]}" -v t="$sample_time" -v lt="${last_time[i]}" \
        'BEGIN { printf "%.3f", (c - lc) / (t - lt) * 100 }')"
    else
      first_cpu[i]="$cpu_seconds"
      first_time[i]="$sample_time"
    fi
    last_cpu[i]="$cpu_seconds"
    last_time[i]="$sample_time"
    if [[ -n "$footprint_mb" ]] && awk -v a="$footprint_mb" -v b="${max_footprint[i]:-0}" 'BEGIN { exit !(a > b) }'; then
      max_footprint[i]="$footprint_mb"
    fi

    elapsed="$(awk -v t="$sample_time" -v s="$start" 'BEGIN { printf "%.1f", t - s }')"
    timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "$timestamp,$elapsed,$pid,$name,$footprint_mb,$footprint_peak_mb,$rss_mb,$cpu_seconds,$cpu_percent" >>"$output"
  done
  ((alive_count > 0)) || break

  if ((duration > 0)); then
    elapsed_int="$(awk -v t="$(now)" -v s="$start" 'BEGIN { printf "%d", t - s }')"
    ((elapsed_int + interval <= duration)) || break
  fi
  sleep "$interval" || true
done

# 最初と最後のサンプルの間の平均 CPU 使用率と、footprint の最大値
echo >&2
echo "pid,name,span_s,cpu_percent_avg,footprint_max_mb" >&2
for i in "${!pids[@]}"; do
  [[ -n "${first_time[i]:-}" ]] || continue
  awk -v pid="${pids[i]}" -v name="${names[i]}" -v fc="${first_cpu[i]}" -v ft="${first_time[i]}" \
    -v lc="${last_cpu[i]}" -v lt="${last_time[i]}" -v mf="${max_footprint[i]:-}" 'BEGIN {
      span = lt - ft
      avg = span > 0 ? sprintf("%.3f", (lc - fc) / span * 100) : ""
      printf "%s,%s,%.1f,%s,%s\n", pid, name, span, avg, mf
    }' >&2
done
echo "記録先: $output" >&2
