#!/usr/bin/env bash
# 8時間待機の追加バッテリー消費（要件定義6章の主指標）を、開始・終了時のバッテリー状態から求める（#52）。
#
# 使い方:
#   battery-log.sh start --label NAME [--note 条件メモ] [--output-dir DIR]
#   battery-log.sh stop  --label NAME [--output-dir DIR]
#   battery-log.sh report [--target NAME --control NAME] [--output-dir DIR]
#
#   start / stop  バッテリー残量（%・mAh）、電圧、AC 接続、スリープ設定を記録する。stop は区間の消費量も出す
#   report        区間ごとの消費量を表示する。--target と --control を指定すると、
#                 対象（utter 常駐）と対照（utter なし）の差を 8 時間あたりに換算して出す
#
# 出力: DIR/battery.csv（start/stop の生の値）、DIR/battery-summary.csv（区間ごとの消費量）、DIR/NAME-pmset.txt
# ioreg からは必要なキーだけを取り出す。シリアル番号などの端末識別子は記録しない。
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output_dir="$script_dir/../out"
label=""
note=""
target=""
control=""

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

(($# > 0)) || usage
command="$1"
shift
while (($# > 0)); do
  case "$1" in
    --label) label="${2:?}"; shift 2 ;;
    --note) note="${2:?}"; shift 2 ;;
    --target) target="${2:?}"; shift 2 ;;
    --control) control="${2:?}"; shift 2 ;;
    --output-dir) output_dir="${2:?}"; shift 2 ;;
    -h | --help) usage ;;
    *) echo "不明な引数: $1" >&2; usage ;;
  esac
done

mkdir -p "$output_dir"
raw_csv="$output_dir/battery.csv"
summary_csv="$output_dir/battery-summary.csv"

# ioreg の AppleSmartBattery から1つのキーの値を取り出す。
# 最上位のキー（"Voltage" = 11575）を優先し、無ければ BatteryData などの辞書内のキー（"RemainingCapacity"=2957）を使う
battery_value() {
  local key="$1"
  local dump value
  dump="$(ioreg -rn AppleSmartBattery)"
  value="$(grep -oE "\"$key\" = [A-Za-z0-9]+" <<<"$dump" | head -n 1 | sed -E 's/.*= //' || true)"
  if [[ -z "$value" ]]; then
    value="$(grep -oE "\"$key\"=[A-Za-z0-9]+" <<<"$dump" | head -n 1 | sed -E 's/.*=//' || true)"
  fi
  printf '%s' "$value"
}

snapshot() {
  local phase="$1"
  local percent remaining full voltage external charging
  percent="$(battery_value CurrentCapacity)"
  # macOS 27 では mAh は BatteryData 内。古い OS では AppleRaw* にある
  remaining="$(battery_value RemainingCapacity)"
  [[ -n "$remaining" ]] || remaining="$(battery_value AppleRawCurrentCapacity)"
  full="$(battery_value FullChargeCapacity)"
  [[ -n "$full" ]] || full="$(battery_value AppleRawMaxCapacity)"
  voltage="$(battery_value Voltage)"
  external="$(battery_value ExternalConnected)"
  charging="$(battery_value IsCharging)"

  if [[ -z "$percent" || -z "$remaining" ]]; then
    echo "バッテリー情報を読めませんでした（ノート型 Mac で実行してください）。" >&2
    exit 69
  fi
  if [[ "$external" == "Yes" || "$charging" == "Yes" ]]; then
    echo "警告: AC 電源に接続されています。電源を外してから計測してください（この行は無効）。" >&2
  fi
  if [[ ! -f "$raw_csv" ]]; then
    echo "label,phase,timestamp,epoch,percent,remaining_mah,full_charge_mah,voltage_mv,external_connected,is_charging,note" >"$raw_csv"
  fi
  local clean_note="${note//,/ }"
  echo "$label,$phase,$(date '+%Y-%m-%d %H:%M:%S %z'),$(date +%s),$percent,$remaining,$full,$voltage,$external,$charging,$clean_note" >>"$raw_csv"
  echo "$phase: ${percent}% / ${remaining} mAh（満充電 ${full} mAh）/ ${voltage} mV / AC=${external}"
}

# raw_csv から label の phase 行（最後のもの）を取り出す
raw_row() {
  awk -F, -v label="$1" -v phase="$2" '$1 == label && $2 == phase { row = $0 } END { print row }' "$raw_csv"
}

case "$command" in
  start)
    [[ -n "$label" ]] || usage
    if [[ -f "$raw_csv" && -n "$(raw_row "$label" start)" ]]; then
      echo "ラベル $label は記録済みです。別の --label を指定してください。" >&2
      exit 73
    fi
    snapshot start
    {
      echo "# pmset -g（開始時のスリープ設定）"
      pmset -g
    } >"$output_dir/$label-pmset.txt"
    echo "記録先: $raw_csv"
    ;;
  stop)
    [[ -n "$label" ]] || usage
    start_row="$(raw_row "$label" start 2>/dev/null || true)"
    if [[ -z "$start_row" ]]; then
      echo "ラベル $label の start がありません。" >&2
      exit 66
    fi
    snapshot stop
    stop_row="$(raw_row "$label" stop)"
    start_time="$(cut -d, -f3 <<<"$start_row")"
    stop_time="$(cut -d, -f3 <<<"$stop_row")"
    # 計測中のスリープ・復帰の回数（pmset -g log は "日付 時刻 TZ 種別" の形式。同じタイムゾーンなら文字列比較で範囲を絞れる）
    sleep_counts="$(pmset -g log | awk -v from="$start_time" -v to="$stop_time" '
      { stamp = $1 " " $2 " " $3 }
      stamp >= from && stamp <= to && $5 != "Requests" {
        if ($4 == "Sleep") s++; else if ($4 == "Wake") w++; else if ($4 == "DarkWake") d++
      }
      END { printf "%d,%d,%d", s, w, d }')"
    if [[ ! -f "$summary_csv" ]]; then
      echo "label,hours,percent_used,mah_used,percent_of_full_used,avg_watts,sleeps,wakes,dark_wakes,ac_during,note" >"$summary_csv"
    fi
    awk -F, -v s="$start_row" -v e="$stop_row" -v counts="$sleep_counts" 'BEGIN {
      split(s, a, ","); split(e, b, ",")
      hours = (b[4] - a[4]) / 3600
      mah = a[6] - b[6]
      full = (a[7] + b[7]) / 2
      volts = (a[8] + b[8]) / 2 / 1000
      watts = hours > 0 ? mah * volts / 1000 / hours : 0
      ac = (a[9] == "Yes" || b[9] == "Yes" || a[10] == "Yes" || b[10] == "Yes") ? "Yes" : "No"
      printf "%s,%.3f,%d,%d,%.3f,%.4f,%s,%s,%s\n", a[1], hours, a[5] - b[5], mah, mah / full * 100, watts, counts, ac, a[11]
    }' >>"$summary_csv"
    tail -n 1 "$summary_csv" | awk -F, '{
      printf "経過 %.2f 時間 / 消費 %d%%（%d mAh = 満充電比 %.3f%%）/ 平均 %.4f W / スリープ %d 回・復帰 %d 回・DarkWake %d 回 / 計測中の AC 接続: %s\n",
        $2, $3, $4, $5, $6, $7, $8, $9, $10
    }'
    echo "記録先: $summary_csv"
    ;;
  report)
    if [[ ! -f "$summary_csv" ]]; then
      echo "集計がありません: $summary_csv" >&2
      exit 66
    fi
    column -s, -t "$summary_csv"
    if [[ -n "$target" || -n "$control" ]]; then
      [[ -n "$target" && -n "$control" ]] || usage
      echo
      awk -F, -v target="$target" -v control="$control" '
        $1 == target { th = $2; tp = $5; tw = $6; found_t = 1 }
        $1 == control { ch = $2; cp = $5; cw = $6; found_c = 1 }
        END {
          if (!found_t || !found_c || th <= 0 || ch <= 0) { print "target / control の集計が見つかりません。"; exit 1 }
          diff = (tp / th - cp / ch) * 8
          printf "8時間あたりの追加消費（満充電比）: %.3f%%  = 対象 %.3f%%/8h − 対照 %.3f%%/8h（6章の目標: 1%% 未満）\n", diff, tp / th * 8, cp / ch * 8
          printf "平均消費電力の差: %.4f W（6章の参考値: 約70Wh機で 0.09W 以下）\n", tw - cw
        }' "$summary_csv"
    fi
    ;;
  *)
    usage
    ;;
esac
