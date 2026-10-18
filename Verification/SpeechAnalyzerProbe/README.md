# SpeechAnalyzerProbe

Phase 0 検証 [#48](https://github.com/harry2480/utter/issues/48)「SpeechAnalyzer の日本語・部分認識」（要件定義 6章・11章）を、人が実機で計測するための使い捨てのコマンドラインツール。
本番コードではなく、`Packages/` からは参照しない。手順書は [docs/Phase0検証-SpeechAnalyzer日本語認識.md](../../docs/Phase0検証-SpeechAnalyzer日本語認識.md)。

できること:

1. `status`: ja_JP の SpeechTranscriber の対応可否、アセットの状態（インストール済みか）、入力形式、権限、端末を表示する
2. `file` / `mic`: 音声ファイルまたはマイク入力を SpeechAnalyzer に流し、暫定（volatile）・確定（final）の結果を、音声の時刻と壁時計の遅延つきで出力する。`--cancel-after` でキャンセルの応答時間も測る
3. `batch`: 評価セットの音声をまとめて認識し、`utter-eval` が読める評価結果の JSON（[docs/精度評価.md](../../docs/精度評価.md) の `EvaluationSample` の配列）を書く
4. 実行中、このプロセスの物理メモリ（`phys_footprint`）を一定間隔で記録する

テレメトリ・外部送信はしない。通信するのは `install` のアセット取得（OS が Apple のサーバーから取得）だけ。

## 必要なもの

- macOS 26 以降の Apple silicon Mac（SpeechAnalyzer は macOS 26 で追加）
- Xcode 26 以降（`DEVELOPER_DIR` で Xcode のツールチェーンを使う）
- `mic` を使う場合はマイクの権限。CLI なので、権限は実行したターミナルアプリ（Terminal / iTerm など）に付く
- 評価用の音声ファイル（人が録音して用意する。リポジトリに含めない）

## ビルド

`scripts/verify.sh` には組み込んでいない（実機・権限が前提のため）。手動でビルドする。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release --package-path Verification/SpeechAnalyzerProbe
probe=Verification/SpeechAnalyzerProbe/.build/release/SpeechAnalyzerProbe
```

メモリと速度を測るため `-c release` でビルドする。マイクと音声認識の権限ダイアログ用に、`Support/Info.plist` を実行ファイルに埋め込んでいる。

## 実行手順

以下はリポジトリのルートで実行する。

### 1. 対応状況とアセット（完了条件: 日本語モデルの有無・対応デバイス・必要 OS）

```sh
$probe status                # 副作用なし。結果をそのまま記録に貼る
$probe install               # ロケールを予約し、アセットをダウンロード（通信あり）
$probe status                # AssetInventory.status が installed になったか確認
$probe authorize             # （任意）音声認識とマイクの権限を要求する
```

- `file` / `mic` / `batch` は `AssetInventory.status` が `installed` でないと実行しない
- 音声認識の権限（`SFSpeechRecognizer`）が SpeechAnalyzer に必要かは未確認。`authorize` をせずに `file` が動くかも記録する

### 2. 部分認識と遅延（完了条件: partial / confirmed の出方と遅延）

```sh
# 音声ファイルを実時間どおりに流す（マイク入力の模擬。再現性が高い）
$probe file eval/audio/ja-001.m4a --log Verification/SpeechAnalyzerProbe/output/ja-001.jsonl

# 内蔵マイクから10秒録音して流す（音声は保存しない）
$probe mic --seconds 10 --log Verification/SpeechAnalyzerProbe/output/mic-01.jsonl

# 入力開始から1秒でキャンセルし、応答時間と、キャンセル後に結果が来ないかを確認する
# （--pace realtime の file と mic だけ。音声が指定の秒数より短いと計測されない）
$probe file eval/audio/ja-001.m4a --cancel-after 1
```

標準出力の1行が1つの結果:

```text
1.234s  volatile  audio 0.00-1.10s  lag 0.134s  | （認識本文）
```

| 項目 | 意味 |
|---|---|
| 先頭の秒 | 音声時刻 0 からの壁時計の経過（受信時刻） |
| `volatile` / `final` | 暫定 / 確定（`SpeechTranscriber.Result.isFinal`） |
| `audio a-b` | 結果の音声範囲（`Result.range`） |
| `lag` | 遅延 = 受信時刻 − 結果の音声終了時刻。音声がその時刻に「話し終わった」とみなし、そこから結果が届くまでの時間 |

最後に summary を出す。

| 項目 | 意味 |
|---|---|
| prepareToAnalyze | モデルのロードを含む準備時間（初回と2回目以降で差を見る） |
| 最初の結果（音声0から） | 最初の結果を受け取るまでの秒。発話前の無音を含む |
| 遅延 volatile / final | 上の `lag` の p50 / p95 / 最大 |
| 入力終了→最後の確定 | 入力を止めてから最後の確定結果が届くまで（6章「停止→挿入」の STT 部分） |
| 入力終了→finish 完了 | `finalizeAndFinishThroughEndOfInput()` が戻るまで |
| 実時間比 | 処理時間 ÷ 音声の長さ。`--pace fast` のときの処理速度の目安 |
| phys_footprint | 開始時・計測中の最大・プロセス生涯の最大（MB） |
| キャンセル | `cancelAndFinishNow()` の戻りまでの時間、結果のストリームが終わるまでの時間、呼び出し後に届いた結果の数 |

計測の前提と限界:

- 遅延は `--pace realtime`（`file` の既定）と `mic` のときだけ出す。`--pace fast` では音声を待たずに渡すため遅延は意味を持たず、`-` になる
- `file --pace realtime` は 100ms ごとに、そのチャンクの終わりの時刻になってから渡す。マイクの入力遅延は含まない
- `mic` は最初のバッファの先頭を音声時刻 0 とする。入力デバイスのハードウェア遅延は含まない
- 6章の目標は「準備済みモデル（ロード済み）」の条件。初回（コールドスタート）は別に記録する。`--retention processLifetime` などでモデル保持の違いも比べられる
- `--preset` は `progressive`（既定。`volatileResults` と `fastResults`）、`transcription`（確定のみ）、`timeIndexedProgressive`。各プリセットの `reportingOptions` は `status` に出る

### 3. 精度（完了条件: 日本語・日英混在・開発用語の精度の傾向）

1. 音声を `eval/audio/`（gitignore 済み）に置く。AVAudioFile が読める形式（m4a / wav / aiff / caf など）
2. [manifest.example.json](manifest.example.json) を `eval/audio/speechanalyzer-manifest.json` にコピーして書き換える。キーは `EvaluationSample`（[docs/精度評価.md](../../docs/精度評価.md)）に `audio`（manifest からの相対パス、または絶対パス）を加えたもの。`reference` は発話どおりに書く
3. 認識して評価結果を書き、`utter-eval` で集計する

```sh
$probe batch eval/audio/speechanalyzer-manifest.json \
  --out Verification/SpeechAnalyzerProbe/output/results.json \
  --log Verification/SpeechAnalyzerProbe/output/batch.jsonl
swift run --package-path Packages/UtterEvaluation utter-eval Verification/SpeechAnalyzerProbe/output/results.json
```

- 出力は manifest の `id` / `category` / `reference` / `terms` に `sttOutput`（確定結果をつないだもの）を加えた JSON。認識に失敗した発話は `sttOutput` を省略する（utter-eval では未実施として数える）
- `batch` は既定で `--pace fast`（精度だけを見るため）。標準出力には発話本文を出さず、識別子と計測値だけを出す
- 音声の前処理（音量・無音の除去）はしない

### 4. メモリ（完了条件: 実行時メモリ 500MB 以下、OS 管理領域は別計測）

- `--log` の JSON Lines に `memory` イベント（`--memory-interval` 秒ごと、既定 0.5 秒）で `phys_footprint` を記録する。summary にも最大値を出す
- 測れるのはこのプロセスだけ。SpeechAnalyzer の推論が OS の別プロセスで動く場合、その分は含まれない（6章「OS 管理領域は別計測」）。認識中に別のターミナルで `top -o mem -l 0 -s 1 -stats pid,command,mem` を実行するか Activity Monitor をメモリ順に並べ、認識中に増えるプロセス名と最大値を記録する
- `batch` ではプロセス生涯の最大値は全発話を通した値になる。発話ごとの最大は `memory` イベントの `sampleID` で分けて見る

## 出力の記録先

- 計測結果（status の出力、summary、utter-eval の表、端末・OS・条件）は `docs/計測/` に人が記録する（AC-19）。推測では書かない
- `--log` の JSON Lines と `batch` の結果 JSON は `Verification/SpeechAnalyzerProbe/output/` に置く（gitignore 済み）

## プライバシー

- 音声はこのツールでは保存しない（`mic` も録音をファイルに書かない）
- 認識本文は、計測のために次の場所にだけ出る: `file` / `mic` の標準出力、`--log` の JSON Lines（`result` イベントの `text`）、`batch` の結果 JSON（`sttOutput`）。いずれもローカルだけで、外部へ送らない
- `run` イベントには音声ファイル名だけを記録し、ディレクトリのパスは記録しない
- 実在の個人情報や他人の発話を録音・正解テキストに含めない

## 片付け

```sh
trash Verification/SpeechAnalyzerProbe/output    # ログ・結果（認識本文を含む）
trash Verification/SpeechAnalyzerProbe/.build
$probe release                                    # ロケールの予約を解除（アセットは OS が後で削除する）
```

マイク・音声認識の権限は「システム設定 > プライバシーとセキュリティ」で、実行したターミナルアプリの許可を外す。
