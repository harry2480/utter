# PerfProbe — 速度・待機メモリ・バッテリーの計測道具（#52）

要件定義6章のストレッチ目標（録音開始遅延、停止→挿入の p50/p95、待機時メモリ・CPU、8時間待機の追加バッテリー消費）を、人が実機で計測するための道具。11章「速度ストレッチ目標と待機時50MB・バッテリー1%目標の現実性」の判定材料にする。手順書は [docs/Phase0検証-性能目標.md](../../docs/Phase0検証-性能目標.md)。

- 対象 Issue: #52（要件定義6章・11章、AC-19）
- 本番コードではない使い捨てのプロトタイプ。`Packages/` からは参照しない
- このディレクトリの道具は計測するだけ。**結果は人が実測して `docs/計測/` に記録する。推測で書かない**

## 構成

| パス | 内容 |
|---|---|
| `Sources/PerfProbe/` | Signpost の区間名（`PerfInterval`）と発行（`PerfSignposts`）。外部依存なし。将来アプリ本体が同じ区間名で発行できるようにする |
| `Sources/perf-probe-demo/` | ダミーの区間を発行するデモ。計測パイプラインの動作確認用（マイク・STT・LLM・挿入は行わない） |
| `Sources/PerfProbeAnalysis/`, `Sources/perf-probe-summarize/` | `xctrace export` の XML から区間ごとの n / min / p50 / p95 / max / mean を出し、6章の目標と並べる |
| `scripts/record-signposts.sh` | `xctrace record`（os_signpost）で記録 → 書き出し → 集計 |
| `scripts/summarize-signposts.sh` | 記録済みの `.trace` を集計し直す |
| `scripts/sample-process.sh` | 指定プロセスの Physical footprint と CPU 使用率を一定間隔で CSV に記録 |
| `scripts/battery-log.sh` | 8時間待機の開始・終了時のバッテリー状態を記録し、対照との差を出す |

## 必要なもの

- macOS 26 以降、Xcode（`xctrace` を使う。`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を指定）
- バッテリー計測はノート型 Mac（AC 電源を外して計測）
- 特別な権限は不要。`xctrace` / `vmmap` は自分のユーザーで動くプロセスに対して使う
- 6章の計測そのものには、区間を発行する utter 本体（または各検証プローブ）が必要。アプリ本体はまだ無いため、現時点で実行できるのはデモでの動作確認と、既存プロセスのメモリ・CPU・バッテリーの記録

## ビルドとテスト

`scripts/verify.sh` はこのパッケージをビルドしない（既存チェックを遅くしないため。scripts の shellcheck と Swift の format lint は verify の対象）。手動で次を実行する。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --package-path Verification/PerfProbe
swift test --package-path Verification/PerfProbe
```

## Signpost の区間名

サブシステム `utter.perf`、カテゴリ Points of Interest。区間名は `PerfInterval` だけで定義し、手順書の表と一致させる。Signpost には名前だけを載せ、メッセージ（発話本文・アプリ名・ファイル名など）は付けない。

| 区間名 | 開始 → 終了 | 6章の目標 |
|---|---|---|
| `RecordingStart` | 録音開始の操作（ショートカット押下）→ 最初の音声バッファ受信 | p95 ≤ 200ms |
| `RealtimeFirstText` | 録音開始の操作 → Realtime Preview の初回文字表示 | p95 ≤ 1.5秒 |
| `STTFinalize` | 録音停止 → STT の確定結果 | 内訳（目標なし） |
| `LLMFirstToken` | LLM への要求送信 → 初回トークン | 内訳（目標なし） |
| `LLMComplete` | LLM への要求送信 → 応答完了 | 内訳（目標なし） |
| `Insert` | 挿入開始 → 挿入完了 | 内訳（目標なし） |
| `StopToInsertLocal` | 録音停止 → 挿入完了（ローカル高速入力） | p50 ≤ 300ms、p95 ≤ 700ms |
| `StopToInsertAI` | 録音停止 → 挿入完了（AI整形あり） | p50 ≤ 800ms、p95 ≤ 1.5秒 |
| `ModelLoad` | STT モデルのロード開始 → 完了 | コールドスタートの内訳（計測のみ） |

アプリやプローブ側での使い方:

```swift
import PerfProbe

let signposts = PerfSignposts()
let total = signposts.begin(.stopToInsertLocal)
let text = try await signposts.measure(.sttFinalize) { try await recognizer.finalize() }
try await signposts.measure(.insert) { try await inserter.insert(text) }
signposts.end(total)
```

`RecordingStart` / `RealtimeFirstText` の開始は、ショートカットのイベントを受けた時点にする。ハンドラの後段で開始すると、それより前の遅延が区間に入らず短く測れてしまう。

## 1. 区間の計測（録音開始遅延・停止→挿入・区間内訳）

6章の条件: 10秒程度の発話、準備済みモデル（ロード済み）、内蔵マイク、通常ネットワーク。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd Verification/PerfProbe

# パイプラインの動作確認（ダミー値。結果として記録しない）
swift build -c release --product perf-probe-demo
scripts/record-signposts.sh --label demo-check --process perf-probe-demo \
  --launch -- .build/release/perf-probe-demo signposts --iterations 20

# 本計測: 起動済みのアプリに接続し、記録中に発話→停止→挿入を繰り返す。Ctrl-C か --time-limit で止める
scripts/record-signposts.sh --label local-builtin-mic-01 --attach <PID またはプロセス名> --time-limit 15m
```

- `--attach` にプロセス名を渡して同名のプロセスが複数あると xctrace が失敗する。その場合は PID を渡す
- 条件ごとに `--label` を分けて別の trace にする（例: `local-builtin-mic`、`ai-claude-builtin-mic`、`cold-start`、`bt-mic`）。集計は trace 単位なので、条件を混ぜない
- p95 を見るため、1条件あたり 20 回以上（できれば 40 回以上）繰り返す。集計は最近傍順位法で、n < 20 では p95 = 最大値になる
- コールドスタート（モデル未ロード）は別ラベルで記録し、6章どおり目標とは比較しない（計測のみ）
- Bluetooth マイクは録音開始遅延の目標対象外。別ラベルで記録し、発話冒頭の欠落の有無は録音を聞いて人が確認する
- 記録を止めた時点で終わっていない区間、記録開始前に始まった区間は集計に入らない
- 集計済みの trace は `scripts/summarize-signposts.sh out/<label>.trace [--process 名前]` で再集計できる

出力（`out/`）: `<label>.trace`（Instruments で開ける）、`<label>.intervals.xml`、`<label>.summary.md`（Markdown 表）、`<label>.durations.csv`（1区間1行、ミリ秒）

`summary.md` の「目標内か」は p50/p95 と6章の数値を機械的に比べただけ。計測条件が6章どおりかは人が確認して判定する。

## 2. メモリ・CPU（待機時・録音のみ・STT 実行時・負荷復帰）

```sh
# 待機時: アプリを起動して 5 分置いてから、60 秒間隔で 30 分記録
scripts/sample-process.sh --name <アプリのプロセス名> --interval 60 --duration 1800 --output out/idle-01.csv

# 複数プロセス（例: アプリ本体と STT Worker）を同時に記録
scripts/sample-process.sh --name <アプリ> --name <Worker> --interval 5 --duration 0   # Ctrl-C まで

# 処理後の負荷復帰: 1 秒間隔で記録しながら発話→挿入を行う
scripts/sample-process.sh --name <アプリ> --interval 1 --duration 120 --output out/recovery-01.csv
```

列: `timestamp, elapsed_s, pid, name, footprint_mb, footprint_peak_mb, rss_mb, cpu_time_s, cpu_percent`。終了時に、プロセスごとの平均 CPU 使用率（最初と最後のサンプル間の CPU 時間 ÷ 経過時間）と footprint の最大値を表示する。

- `footprint_mb` は `vmmap --summary` の Physical footprint（Activity Monitor の「メモリ」列と同じ指標）。6章のメモリ目標はこの値で比べる
- `footprint_mb` が空になる場合は `vmmap` が対象を読めていない。同じユーザーで動くプロセスか確かめ、必要なら `sudo` で実行する
- `--name` は開始時に一度だけ `pgrep -x` で PID を引く。計測中にアプリを再起動したら記録し直す
- `cpu_percent` は1コア = 100%。`ps` の CPU 時間は 0.01 秒単位なので、待機時 CPU（目標 0.1%）は 60 秒以上の間隔で見る
- Apple STT はシステムのプロセスで処理される部分があり、6章は「OS管理領域は別計測」としている。どのプロセスが対象かは Activity Monitor で確かめて `--name` に追加する。WhisperKit のモデル・GPU 領域も同様に別に記録する
- 負荷復帰（目標 5 秒以内）は、挿入完了の時刻から `cpu_percent` が待機時の水準に戻るまでの時間を CSV から読む

## 3. 8時間待機の追加バッテリー消費

6章の主指標は「同条件の対照測定」との差。utter を常駐させた計測（対象）と、utter を起動しない計測（対照）を、同じ条件で別々に行う。

```sh
# 対照（utter を起動しない）
scripts/battery-log.sh start --label control-01 --note "画面輝度50% Wi-Fi on 蓋開け caffeinate -i"
#   … 8 時間待機 …
scripts/battery-log.sh stop --label control-01

# 対象（utter を待機状態で常駐）
scripts/battery-log.sh start --label utter-idle-01 --note "画面輝度50% Wi-Fi on 蓋開け caffeinate -i"
#   … 8 時間待機 …
scripts/battery-log.sh stop --label utter-idle-01

scripts/battery-log.sh report --target utter-idle-01 --control control-01
```

- AC 電源を外して計測する（接続中は警告し、集計の `ac_during` が `Yes` になる。その計測は無効）
- 消費量は表示上の % ではなく mAh（`RemainingCapacity`）の差を満充電容量で割った値（`percent_of_full_used`）で見る。1% 未満の差は表示上の % では分からない
- 「待機」の条件（Mac をスリープさせるか、`caffeinate -i` で起こしておくか、画面の状態、ネットワーク）は人が決め、対象と対照で揃えて `--note` に残す。スリープ・復帰の回数も集計に出るので、条件が揃っているかの確認に使う
- 1回ずつの差はバッテリー残量の推定誤差に埋もれやすい。対象・対照を複数回ずつ繰り返す
- 開始時の `pmset -g`（スリープ設定）を `out/<label>-pmset.txt` に残す

## 6章の目標との対応

| 6章の指標 | 道具 | 見る値 | 目標 |
|---|---|---|---|
| 録音開始遅延 | record-signposts | `RecordingStart` の p95 | ≤ 200ms |
| Realtime初回文字表示 | record-signposts | `RealtimeFirstText` の p95 | ≤ 1.5秒 |
| ローカル高速入力：停止→挿入 | record-signposts | `StopToInsertLocal` の p50 / p95 | ≤ 300ms / ≤ 700ms |
| AI整形あり：停止→挿入 | record-signposts | `StopToInsertAI` の p50 / p95（内訳: `STTFinalize`、`LLMFirstToken`、`LLMComplete`、`Insert`） | ≤ 800ms / ≤ 1.5秒 |
| コールドスタート：停止→挿入 | record-signposts（別ラベル） | `StopToInsertLocal` / `StopToInsertAI`、`ModelLoad` | 計測のみ |
| 待機時アプリメモリ | sample-process | `footprint_mb`（最大値） | ≤ 50MB |
| 録音のみのアプリメモリ | sample-process | `footprint_mb`（最大値） | ≤ 100MB |
| Apple STT / WhisperKit 実行時 | sample-process（関連プロセスも指定） | `footprint_mb`（最大値） | ≤ 500MB / ≤ 1GB |
| 待機時CPU | sample-process | 終了時の `cpu_percent_avg` | 平均 ≤ 0.1% |
| 8時間待機の追加バッテリー消費 | battery-log | `report` の追加消費 | < 1% |
| 待機時追加消費電力（参考） | battery-log | `report` の平均消費電力の差 | 約70Wh機で ≤ 0.09W |
| 処理後の負荷復帰 | sample-process（1秒間隔） | 挿入後に `cpu_percent` が戻るまでの秒数 | ≤ 5秒 |

6章の数値を再設定したら、`Sources/PerfProbeAnalysis/PerfTarget.swift` と上の表も直す。

## 出力の記録先とプライバシー

- 出力はすべて `Verification/PerfProbe/out/`（gitignore 済み）。結果は人が `docs/計測/` に、計測条件（機種・OS・モデル・マイク・ネットワーク・回数）と一緒に転記する
- Signpost には区間名しか載せないため、trace・XML・CSV に発話本文は含まれない。ただし `.trace` には同じ時間帯の他プロセスの Signpost やプロセス名が入る場合があるため、trace と XML はコミットしない（`*.trace` は gitignore 済み）
- `battery-log.sh` は ioreg から必要なキーだけを取り出し、シリアル番号などの端末識別子は記録しない
- テレメトリ・外部送信はない

## 片付け

```sh
trash Verification/PerfProbe/out Verification/PerfProbe/.build
```
