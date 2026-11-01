#!/usr/bin/env bash
# CPU・GPU・Neural Engine の消費電力と熱の状態を powermetrics で記録し、区間ごとの平均を出す（#49, #52）。
#
# 使い方:
#   sudo power-log.sh record --label NAME [--interval-ms 1000] [--duration 秒] [--output-dir DIR]
#   power-log.sh parse  --label NAME [--output-dir DIR]
#   power-log.sh report [--target NAME --control NAME] [--output-dir DIR]
#
#   record  powermetrics（cpu_power・gpu_power・ane_power・thermal）の生の出力を DIR/NAME-powermetrics.txt に保存し、
#           終わったら parse する。powermetrics は管理者権限が要るため sudo で実行する。終了は --duration か Ctrl-C
#   parse   保存済みの生の出力から DIR/NAME-power.csv（サンプルごと）を作り、平均を DIR/power-summary.csv に足す
#   report  区間ごとの平均を表示する。--target と --control を指定すると、対象（例: 推論中）から
#           対照（例: 同じ条件の待機）を引いた差を出す
#
# 列（NAME-power.csv）: sample, elapsed_ms, cpu_mw, gpu_mw, ane_mw, combined_mw, thermal_pressure
# 消費電力は SoC の CPU・GPU・ANE の分だけで、画面・SSD・周辺機器は含まない（powermetrics の推定値）。
# プロセスごとの値ではないため、ほかのアプリを閉じ、同じ条件で対照を測って差を見る。
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output_dir="$script_dir/../out"
label=""
interval_ms=1000
duration=0
target=""
control=""

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

(($# > 0)) || usage
command="$1"
shift
while (($# > 0)); do
  case "$1" in
    --label) label="${2:?}"; shift 2 ;;
    --interval-ms) interval_ms="${2:?}"; shift 2 ;;
    --duration) duration="${2:?}"; shift 2 ;;
    --target) target="${2:?}"; shift 2 ;;
    --control) control="${2:?}"; shift 2 ;;
    --output-dir) output_dir="${2:?}"; shift 2 ;;
    -h | --help) usage ;;
    *) echo "不明な引数: $1" >&2; usage ;;
  esac
done

[[ "$interval_ms" =~ ^[1-9][0-9]*$ ]] || { echo "--interval-ms は正の整数で指定してください" >&2; exit 64; }
[[ "$duration" =~ ^[0-9]+$ ]] || { echo "--duration は 0 以上の整数（秒）で指定してください" >&2; exit 64; }

summary_csv="$output_dir/power-summary.csv"

require_label() {
  [[ -n "$label" ]] || { echo "--label を指定してください" >&2; exit 64; }
  [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "--label は英数字と . _ - だけにしてください" >&2; exit 64; }
}

# powermetrics のテキスト出力を CSV にする。
# 1サンプルは「*** Sampled system activity (...) (1004.12ms elapsed) ***」で始まる。
# 消費電力は Processor の節の「CPU Power」「GPU Power」「ANE Power」「Combined Power (CPU + GPU + ANE)」の行から取る。
# gpu_power のサンプラーを足すと GPU の節にも「GPU Power」が出るため、各サンプルで最初の値だけを使う。
# 熱の状態は「Current pressure level: Nominal」の行から取る。
parse_raw() {
  local raw="$1"
  awk '
    function flush() {
      if (in_sample && combined != "") {
        printf "%d,%s,%s,%s,%s,%s,%s\n", n, elapsed, cpu, gpu, ane, combined, thermal
      }
    }
    function mw(line,   v) {
      v = line
      sub(/^[^:]*:[ \t]*/, "", v)
      sub(/[ \t]*mW.*$/, "", v)
      return (v ~ /^[0-9]+(\.[0-9]+)?$/) ? v : ""
    }
    BEGIN { print "sample,elapsed_ms,cpu_mw,gpu_mw,ane_mw,combined_mw,thermal_pressure"; n = 0 }
    /^\*\*\* Sampled system activity/ {
      flush()
      n++; in_sample = 1
      elapsed = ""; cpu = ""; gpu = ""; ane = ""; combined = ""; thermal = ""
      if (match($0, /\([0-9.]+ms elapsed\)/)) {
        elapsed = substr($0, RSTART + 1, RLENGTH - 1)
        sub(/ms elapsed\)/, "", elapsed)
      }
      next
    }
    /^CPU Power:/ && cpu == "" { cpu = mw($0) }
    /^GPU Power:/ && gpu == "" { gpu = mw($0) }
    /^ANE Power:/ && ane == "" { ane = mw($0) }
    /^Combined Power/ && combined == "" { combined = mw($0) }
    /^Current pressure level:/ && thermal == "" {
      thermal = $0
      sub(/^Current pressure level:[ \t]*/, "", thermal)
      gsub(/[ \t,]+/, "", thermal)
    }
    END { flush() }
  ' "$raw"
}

# CSV の平均を1行（label,samples,cpu_mw,gpu_mw,ane_mw,combined_mw,thermal_levels）で出す
summarize_csv() {
  local name="$1" csv="$2"
  awk -F, -v name="$name" '
    NR == 1 { next }
    {
      n++
      if ($3 != "") { cs += $3; cn++ }
      if ($4 != "") { gs += $4; gn++ }
      if ($5 != "") { as += $5; an++ }
      if ($6 != "") { ms += $6; mn++ }
      if ($7 != "" && !($7 in seen)) { seen[$7] = 1; levels = levels (levels == "" ? "" : "/") $7 }
    }
    function avg(s, c) { return c > 0 ? sprintf("%.1f", s / c) : "" }
    END {
      if (n == 0) { exit 1 }
      printf "%s,%d,%s,%s,%s,%s,%s\n", name, n, avg(cs, cn), avg(gs, gn), avg(as, an), avg(ms, mn), levels
    }
  ' "$csv"
}

do_parse() {
  require_label
  local raw="$output_dir/$label-powermetrics.txt"
  local csv="$output_dir/$label-power.csv"
  [[ -s "$raw" ]] || { echo "生の出力がありません: $raw" >&2; exit 1; }
  parse_raw "$raw" >"$csv"
  local line
  if ! line="$(summarize_csv "$label" "$csv")"; then
    echo "消費電力の行を読み取れませんでした（powermetrics の出力の形式を確かめてください）: $raw" >&2
    exit 1
  fi
  if [[ ! -f "$summary_csv" ]]; then
    echo "label,samples,cpu_mw,gpu_mw,ane_mw,combined_mw,thermal_levels" >"$summary_csv"
  fi
  # 同じラベルを測り直したときは古い行を置き換える
  local tmp
  tmp="$(mktemp)"
  awk -F, -v name="$label" 'NR == 1 || $1 != name' "$summary_csv" >"$tmp"
  echo "$line" >>"$tmp"
  mv "$tmp" "$summary_csv"
  echo "$csv"
  echo "$line"
}

do_record() {
  require_label
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "powermetrics は管理者権限が要ります。sudo を付けて実行してください" >&2
    exit 77
  fi
  mkdir -p "$output_dir"
  local raw="$output_dir/$label-powermetrics.txt"
  local args=(--samplers "cpu_power,gpu_power,ane_power,thermal" -i "$interval_ms")
  if ((duration > 0)); then
    # 1サンプル目は区間の始まりの値が揃わないことがあるため、1つ多く取る
    args+=(-n "$((duration * 1000 / interval_ms + 1))")
  fi
  echo "記録中: $raw（終了は Ctrl-C）" >&2
  # Ctrl-C で powermetrics だけを止め、続けて parse する
  trap 'true' INT
  powermetrics "${args[@]}" >"$raw" || true
  trap - INT
  # sudo で作ったファイルを、実行した利用者が読み書きできるようにする
  if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
    chown "$SUDO_UID:$SUDO_GID" "$output_dir" "$raw"
  fi
  do_parse
  if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
    chown "$SUDO_UID:$SUDO_GID" "$output_dir/$label-power.csv" "$summary_csv"
  fi
}

do_report() {
  [[ -f "$summary_csv" ]] || { echo "記録がありません: $summary_csv" >&2; exit 1; }
  column -s, -t "$summary_csv"
  if [[ -n "$target" || -n "$control" ]]; then
    [[ -n "$target" && -n "$control" ]] || { echo "--target と --control は両方指定してください" >&2; exit 64; }
    awk -F, -v t="$target" -v c="$control" '
      $1 == t { for (i = 3; i <= 6; i++) tv[i] = $i; ft = 1 }
      $1 == c { for (i = 3; i <= 6; i++) cv[i] = $i; fc = 1 }
      function d(i) { return (tv[i] != "" && cv[i] != "") ? sprintf("%+.1f", tv[i] - cv[i]) : "-" }
      END {
        if (!ft || !fc) { print "--target または --control のラベルが記録にありません" > "/dev/stderr"; exit 1 }
        printf "\n差（%s − %s, mW）: CPU %s / GPU %s / ANE %s / 合計 %s\n", t, c, d(3), d(4), d(5), d(6)
      }
    ' "$summary_csv"
  fi
}

case "$command" in
  record) do_record ;;
  parse) do_parse ;;
  report) do_report ;;
  *) echo "不明なコマンド: $command" >&2; usage ;;
esac
