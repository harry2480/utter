# WhisperKitProbe

Phase 0 検証 [#49](https://github.com/harry2480/utter/issues/49)「WhisperKit のモデル選定・メモリ・安定性」で、人が実機で計測するための使い捨てのコマンドです。
本番コードではありません。`Packages/` からは参照せず、`scripts/verify.sh` にも組み込みません（WhisperKit の取得とビルドが重いため）。

手順書: [docs/Phase0検証-WhisperKitモデル選定.md](../../docs/Phase0検証-WhisperKitモデル選定.md)、精度の集計: [docs/精度評価.md](../../docs/精度評価.md)

## 計測できること

| 項目 | コマンド | 出力 |
|---|---|---|
| モデルの取得時間・ディスク上のサイズ | `fetch` | `summary.csv` の `download` 行 |
| 初回ロード時間（取得直後。Core ML のデバイス向け特化を含む） | `fetch` | `summary.csv` の `load_first` 行 |
| 2回目以降のロード時間 | `bench` / `eval` | `summary.csv` の `load` 行 |
| 推論時間と RTF（推論時間 ÷ 音声の長さ）。日本語を指定 | `bench` | `summary.csv` の `transcribe` 行 |
| 連続 N 回の推論の時間・メモリ・熱状態の推移（安定性） | `bench --runs N` | `summary.csv` の `transcribe` 行、`memory.csv` |
| 区間ごとのピーク物理メモリ（phys_footprint）と、推論後・アンロード後の解放 | 全コマンド | `summary.csv`、`memory.csv` |
| 評価セットの STT 結果（`utter-eval` で CER・用語正答率を集計） | `eval` | `samples.json` |

熱・電力は、このコマンドの外で `powermetrics` を並行して記録します（後述）。

## 必要なもの

- Apple Silicon の Mac、macOS 26 以降、Xcode 26 以降
- 推論する音声ファイル（wav / m4a / caf / aiff / mp3 / flac）。**人が用意し、リポジトリに置かない**
- 通信は `fetch` の実行時だけ（Hugging Face からモデルとトークナイザーを取得）。`bench` / `eval` は通信しません
  - WhisperKit はローカルのトークナイザーが無い・読めないとき、`download: false` でも Hugging Face から取得し直します。そのため `bench` / `eval` はロード前に、トークナイザーを判定できること・`tokenizer.json` と `tokenizer_config.json` がそろっていて WhisperKit と同じ経路で手元から読み込めることを確かめ、満たさなければ計測せずに止めます。止まったら該当フォルダを消して `fetch` をやり直してください
  - それでも通信しないことは、計測中にネットワークを切るか通信を監視して確かめてください（#47 の D-6 で、utter 側で取得・検証してから WhisperKit に渡すと決定）
- マイク・アクセシビリティなどの権限は不要です

## ビルド

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -c release --package-path Verification/WhisperKitProbe
```

計測は `-c release` でビルドしたものを使ってください（debug ビルドでは前後処理が遅くなります）。
初回は WhisperKit の取得とビルドに数分かかります。WhisperKit は `1.1.1` に固定しています（`Package.resolved` をコミット済み）。

以下の例では、ビルドしたコマンドを変数に入れておきます。

```sh
probe=Verification/WhisperKitProbe/.build/release/whisperkit-probe
```

## 使い方

### 1. 取得と初回ロード（`fetch`）

```sh
$probe fetch --model openai_whisper-tiny
```

- モデルとトークナイザーは既定で `$TMPDIR/utter-whisperkit-probe/models/`（リポジトリの外）に保存されます。`--models-dir` で変更できますが、リポジトリの中には置かないでください
- 取得直後のロードを `load_first` として記録します。これがこの Mac での初回ロード時間です。`tokenizer_load_s` にはトークナイザーの取得（通信）時間が入るため、初回ロード時間は `wall_s − tokenizer_load_s` を目安にしてください
- 同じモデルで `fetch` を再実行すると、取得は差分確認だけになり、`load_first` もシステムのキャッシュが効いた値になります。**初回の値は、そのモデルで最初に実行した `fetch` のものを記録してください**

モデル名は [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main) のフォルダ名をそのまま指定します。軽いものから順に計測します（2026-10-18 時点の例）。

| モデル名 | 備考 |
|---|---|
| `openai_whisper-tiny` | 多言語 |
| `openai_whisper-base` | 多言語 |
| `openai_whisper-small` / `openai_whisper-small_216MB` | 多言語 / 量子化版 |
| `openai_whisper-medium` | 多言語 |
| `openai_whisper-large-v3-v20240930_626MB` / `openai_whisper-large-v3-v20240930_turbo_632MB` | large-v3 turbo 系の量子化版 |

`.en` で終わるモデルは英語専用のため、日本語の計測には使いません。

### 2. ロード・推論・連続推論（`bench`）

```sh
$probe bench --model openai_whisper-base --audio ~/utter-eval-audio/sample-10s.wav --runs 10
```

| オプション | 既定 | 内容 |
|---|---|---|
| `--runs` | 10 | 連続して推論する回数（安定性・熱の確認は 30〜50 回など多めに） |
| `--interval-s` | 0 | 各回の間に空ける秒数（実際の使い方に近づける場合に指定） |
| `--idle-after-s` | 10 | 全回の後、何もせず記録する秒数（推論後のメモリ解放・負荷復帰の確認） |
| `--compute` | `default` | Core ML の計算ユニット。`default`（WhisperKit 既定: エンコーダー・デコーダーとも ANE）/ `ane` / `gpu` / `cpu` |
| `--chunking` | `vad` | 30秒を超える音声の分割方法（`none` / `vad`） |
| `--interval-ms` | 100 | `memory.csv` に記録する間隔 |
| `--out` | `$TMPDIR/utter-whisperkit-probe/out/<コマンド>-<モデル>-<日時>/` | 出力先 |

- 音声は事前に 16kHz モノラルに変換して読み込み、推論時間には含めません
- 推論は日本語を指定し（`language: ja`）、言語判定はしません。温度 0 でも、各回の結果が完全に一致するとは限りません（`same_as_first` で確認できます）
- 失敗（例外、または出力が空）は `success=false` として記録し、残りの回を続けます。成功率は `transcribe` 行の `success` から求めます
- 最後に `unload` 行でモデルを解放した後のメモリを記録します

### 3. 精度評価（`eval`）

```sh
$probe eval --model openai_whisper-base --set eval/results.json --audio-dir eval/audio
swift run --package-path Packages/UtterEvaluation utter-eval <出力された samples.json>
```

- `--set` は [docs/精度評価.md](../../docs/精度評価.md) の評価セット（`EvaluationSample` の配列）。各発話の音声を `--audio-dir` に `<id>.wav`（など）で置きます
- 出力の `samples.json` は、`id` / `category` / `reference` / `terms` を引き継ぎ、`sttOutput` に WhisperKit の結果を入れたものです。`refinedOutput` と `meaningChanges` は別の STT の結果に対するものになるため引き継ぎません
- 音声がない・推論に失敗した発話は `sttOutput` なしで残し、`utter-eval` の集計からは外れます（件数は表示されます）

## 出力ファイル

| ファイル | 内容 |
|---|---|
| `environment.txt` | 実行日時、引数、WhisperKit のバージョン、モデル名、Mac の機種（`hw.model`）、OS、メモリ量、低電力モード、開始時の熱状態 |
| `summary.csv` | 区間ごとに1行。`phase`（`download` / `load_first` / `load` / `transcribe` / `eval` / `idle_after_runs` / `unload`）、`wall_s`、`audio_s`、`rtf`、ロード内訳（`encoder_load_s` / `decoder_load_s` / `tokenizer_load_s`）、区間の開始・終了・ピークのメモリ（MB）、プロセス開始からの最大メモリ、熱状態、出力の文字数、成否 |
| `memory.csv` | `--interval-ms` ごとの phys_footprint（MB）、プロセス開始からの最大値、熱状態、そのときの区間 |
| `samples.json` | `eval` のみ。`utter-eval` が読める形式 |

CSV は1行ずつ書き込むため、途中で異常終了・フリーズしても、それまでの行は残ります。

### メモリの指標について

- `footprint_*_mb` はこのプロセスの **phys_footprint**（アクティビティモニタの「メモリ」列と同じ指標）です。Core ML が GPU 用に確保した領域の一部は含まれます
- `footprint_peak_mb` は区間中のサンプルと区間の開始・終了時点の最大値です。サンプルの間の瞬間的なピークは `lifetime_max_mb`（カーネルが記録するプロセス開始からの最大値。サンプリング間隔に依存しない）で確認してください
- **ANE 用のコンパイル・実行はシステムのプロセス（`ANECompilerService`、`aned` など）で行われ、このプロセスの値には含まれません**。要件定義 6章の「モデル・GPU 領域を別計測」のため、ロード・推論中にアクティビティモニタでこれらのプロセスのメモリを記録してください

## 熱・電力・フリーズの確認

`bench` と並行して、別のターミナルで `powermetrics` を記録します。

```sh
sudo powermetrics --samplers cpu_power,gpu_power,ane_power,thermal -i 1000 -o ~/utter-powermetrics.txt
```

- 連続推論（例: `--runs 50 --interval-s 5`）中の CPU / GPU / ANE の電力と熱の推移を、`summary.csv` の `thermal_state` と合わせて記録します
- Mac 全体のフリーズ・再起動が起きた場合は、日時・モデル・`--compute`・何回目だったか（`summary.csv` の最後の行）を記録します。LM Studio 固有の原因究明は対象外です（要件定義 10章）
- 重いモデル（medium 以上）は、保存していない作業を閉じてから実行してください

## 結果の記録

計測値は推測で書かず、実測した値だけを [docs/計測/](../../docs/計測/) に記録します（Issue #49 の完了条件、AC-19）。
記録には `environment.txt` の内容（機種・OS・メモリ量）と、モデル名・`--compute`・音声の長さを必ず添えてください。
11章の判定（安定性に問題があればより小型のモデル、それでも不成立なら Apple STT 単独）も結論として残します。

## プライバシー

- テレメトリ・解析送信はありません。通信は `fetch` の Hugging Face からの取得だけです
- WhisperKit のログは無効にしており、発話本文を標準出力・ログに出しません
- `bench` は発話本文を保存しません（`output_chars` に文字数だけを記録します）
- **`eval` の `samples.json` には STT の結果（発話本文）が入ります**。ローカルの出力先にだけ書き込みます。集計・記録が済んだら削除してください（`trash <出力先>`）。実在の個人情報を含む発話を評価セットに使わないでください（docs/精度評価.md）
- `environment.txt` には実行時の引数（音声ファイルのパスなど）が入ります。`docs/計測/` に転記するときは、必要な項目だけを写してください

## 片付け

```sh
trash "$TMPDIR/utter-whisperkit-probe"        # モデル・トークナイザー・計測出力
trash Verification/WhisperKitProbe/.build    # 依存とビルド成果物
```

Core ML がシステム側に作るコンパイル済みモデルのキャッシュは、このコマンドでは削除しません。

## モデル重みのライセンスと取得元

確認日: 2026-10-18。採用時のライセンス判断は #47 と合わせて行います。

| 対象 | 取得元 | ライセンス | 出典 |
|---|---|---|---|
| WhisperKit（Swift パッケージ、1.1.1） | https://github.com/argmaxinc/WhisperKit | MIT | リポジトリの `LICENSE`（Copyright (c) 2024 argmax, inc.） |
| Core ML 変換済みモデル（本コマンドが取得するもの） | https://huggingface.co/argmaxinc/whisperkit-coreml | MIT | モデルカードのメタデータ `license: mit` |
| 元の Whisper モデル（openai_whisper-*） | https://github.com/openai/whisper | MIT | README「Whisper's code and model weights are released under the MIT License」と `LICENSE`（Copyright (c) 2022 OpenAI） |
| 元の Whisper モデル（Hugging Face 版） | https://huggingface.co/openai/whisper-base など | Apache-2.0（モデルカードの表記） | 例: https://huggingface.co/openai/whisper-large-v3 のメタデータ `license: apache-2.0` |
| トークナイザー（`fetch` が取得する `openai/whisper-*` の `tokenizer.json` など） | https://huggingface.co/openai | 上の Hugging Face 版と同じ | 同上 |
| distil-whisper（distil-whisper_distil-large-v3 を使う場合） | https://huggingface.co/distil-whisper/distil-large-v3 | MIT | モデルカードのメタデータ `license: mit` |

- OpenAI の GitHub では MIT、Hugging Face のモデルカードでは Apache-2.0 と表記が異なります。どちらも Apache-2.0 の本プロジェクトと両立しますが、配布時の表記は #47 の D-3 で `THIRD_PARTY_NOTICES.md` に置くと決まっています（採用時に追記）
- モデルは Hugging Face の `main` を取得するため、取得した時点の版を記録する場合は、取得日と `https://huggingface.co/api/models/argmaxinc/whisperkit-coreml` の `sha` を控えてください
