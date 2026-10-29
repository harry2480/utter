# SpeechAnalyzer の実機計測（macOS・マイク入力・2026-10-29）

Phase 0 検証 [#48](https://github.com/harry2480/utter/issues/48) の計測記録。
手順・用語は [Verification/SpeechAnalyzerProbe](../../Verification/SpeechAnalyzerProbe/README.md)、
検証の全体と判定案は [Phase0検証-SpeechAnalyzer日本語認識.md](../Phase0検証-SpeechAnalyzer日本語認識.md)。

## 条件

- 実行日：2026-10-29
- 機種：Mac17,2・Apple M5・メモリ 24GB
- OS：macOS 27.0.1（Build 26A434）
- 入力：内蔵マイク（`mic`）。部屋は静か。話者は1人
- ロケール：`ja_JP`（解決後も `ja_JP`）
- プリセット：`progressive`（`volatileResults`・`fastResults`）、`--retention whileInUse`
- ビルド：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --package-path Verification/SpeechAnalyzerProbe`
- 話した内容は、機密情報を含まないテスト用の文だけ
- 各回は別のプロセスで1回ずつ実行した。`prepareToAnalyze` は毎回1回目の値

## 手順1：モデルの取得（`install` → `status`）

- `install` は 0.09 秒で終わり、ダウンロードは起きなかった。ロケールを予約しただけで、`AssetInventory.status` が `supported` から `installed` に変わった
- 日本語モデルは、この Mac に最初から入っていた（取得前から `installedLocales` に `ja_JP` が含まれていたのはこのため）
- 読み取れること（推測）：`AssetInventory.status` は、モデルが端末に入っていて、さらにそのアプリがロケールを予約しているときに `installed` を返す。アプリ（`SpeechAnalyzerAssets`）も取得の前に `reserve(locale:)` を呼ぶので、この Mac では「モデルを取得」ですぐに使える状態になるはず。アプリでの確認はまだしていない

## 手順3：話して認識させる

再現のコマンド（`<名前>` と秒数は回ごとに変える）：

```sh
Verification/SpeechAnalyzerProbe/.build/release/SpeechAnalyzerProbe mic --seconds 15 \
  --log Verification/SpeechAnalyzerProbe/output/<名前>.jsonl
```

| 回 | 録音 | 話した内容 | 確定テキスト | 発話の音声範囲（確定） |
|---|---|---|---|---|
| A | 10 秒 | 「こんにちは。外国人登録の手続きは8月20日までで、手数料は100円です」 | こんにちは。 | 7.50–10.10 秒 |
| B | 10 秒 | 同上 | こんにちは。外国人登録の手続きは 8月 20日までで | 3.78–10.10 秒 |
| C | 15 秒 | 「GitHub の Pull Request をレビューして、Swift のテストを直す」 | GitHubのプロリクエストをレビューして、数質のテストを直す | 4.74–9.42 秒 |
| D | 15 秒 | 「明日の会議は午後3時からです」→ 間を空けて「あいうえお」 | 明日の会議は午後 3時からです。あいうえお | 3.90–8.58 秒、11.52–14.70 秒 |

- A・B は 10 秒の録音時間で発話が途中で切れた（話し始めが遅れたため）。認識の誤りではない
- ログ：C は `mic-02.jsonl`、D は `mic-03.jsonl`（`output/` は gitignore 済み）。A と B は同じファイル名で実行して上書きされたため、ログは残っていない。A・B の値は実行時に標準出力に出た summary から写した

### summary の値

| 項目 | A | B | C | D |
|---|---|---|---|---|
| prepareToAnalyze | 0.118 s | 0.041 s | 0.051 s | 0.043 s |
| 結果の数（volatile / final） | 6 / 1 | 24 / 1 | 30 / 1 | 19 / 2 |
| 最初の結果（音声 0 から） | 8.819 s | 4.915 s | 5.917 s | 4.918 s |
| 遅延 volatile p50 / p95 / 最大 | 0.025 / 0.026 / 0.026 s | 0.024 / 0.039 / 0.131 s | 0.035 / 0.046 / 0.047 s | 0.026 / 0.039 / 0.039 s |
| 遅延 final p50 / p95 / 最大 | 0.101 s（1 件） | 0.216 s（1 件） | 0.362 s（1 件） | 0.280 / 0.436 / 0.436 s |
| 入力終了→最後の確定 | 0.034 s | 0.097 s | 0.000 s | 0.032 s |
| 入力終了→finish 完了 | 0.037 s | 0.099 s | 0.035 s | 0.051 s |
| 実時間比 | 1.010 | 1.022 | 1.009 | 1.010 |
| phys_footprint 最大（計測中 / 生涯） | 6.3 / 6.3 MB | 6.2 / 6.3 MB | 6.2 / 6.3 MB | 6.2 / 6.3 MB |

### 観察

- **暫定結果の届き方**：暫定結果は約 1 秒ごとに、数文字ずつまとめて届く（B では 4.9・5.9・6.8・7.8・8.8・9.7 秒）。summary の `lag` は「届いた結果の音声範囲の終わり → 受け取り」なので 0.02〜0.05 秒と小さいが、話してから画面に出るまでは最大で約 1 秒遅れると読むのが正しい
- **話し始め → 最初の文字**：確定結果の範囲の始まりを話し始めとみなすと、B が 3.78 → 4.915 秒（1.14 秒）、C が 4.74 → 5.917 秒（1.18 秒）、D が 3.90 → 4.918 秒（1.02 秒）。6章の「Realtime 初回文字表示 p95 ≤ 1.5 秒」の範囲内だが、3 件だけで p95 は出せない。範囲の始まりが話し始めと一致するかも確かめていない
- **確定結果のタイミング**：黙ると、録音を止める前に確定結果が届く（C は話し終えた 9.42 秒の 0.36 秒後。D の 1 文目は 8.58 秒の 0.28 秒後）。間を空けた発話は、別の確定結果になる（D）
- **末尾の欠け**：D の 2 つ目の発話は、暫定結果が「あいうえ」で止まり、最後の「お」は録音を止めたあとの確定結果で初めて出た。止めたあとに `finalizeAndFinishThroughEndOfInput()` で確定まで待てば末尾は欠けない。暫定結果だけを使うと最後の音が欠ける
- **最後の暫定結果のあとに確定結果が届いたか**：B・C・D のすべてで届いた。ログの残る C・D では、最後の確定結果の範囲がそれまでの暫定結果の範囲を覆っていた（D：最後の暫定結果は 8.58–12.60 秒・`resultsFinalizationTime` 8.58、最後の確定結果は 11.52–14.70 秒・`resultsFinalizationTime` 14.70）。この 4 回では、`TranscriptionEventMapper.completedText` が足す末尾の暫定部分は空になる
- **精度の傾向**（少数サンプル。数値の評価はしていない）
  - 日本語の一般的な文：誤りなし。句読点（「。」「、」）が付く
  - 数字：「8月 20日」「午後 3時」のように、数字の前後に半角スペースが入る
  - 開発用語：「GitHub」は正しく出た（暫定では「KitHu」と揺れた）。「Pull Request」は「プロリクエスト」、「Swift」は「数質」になった。暫定結果でも「ツイ」「水質」「数質」と揺れた
- **メモリ**：プローブのプロセスは、A〜D のどれも計測中の最大が 6.2〜6.3 MB、プロセス生涯の最大が 6.3 MB（上の表）。推論は OS の別のプロセスで動くとみられ、その分は含まれない（OS 側のメモリは未計測）

## 手順4：オフライン

未実施。Wi-Fi を切ると Claude Code が止まるため、今回は行わなかった。

## 手順5：キャンセル（`--cancel-after`）

```sh
# E：話し始める前に止める
Verification/SpeechAnalyzerProbe/.build/release/SpeechAnalyzerProbe mic --seconds 10 --cancel-after 1 \
  --log Verification/SpeechAnalyzerProbe/output/mic-cancel-before-speech.jsonl
# F：話している途中で止める（表示が出たらすぐ話し始め、止まるまで話し続ける）
Verification/SpeechAnalyzerProbe/.build/release/SpeechAnalyzerProbe mic --seconds 10 --cancel-after 6 \
  --log Verification/SpeechAnalyzerProbe/output/mic-cancel.jsonl
```

| 回 | 止めた時点 | 呼び出し時刻 | 戻りまで | 結果の終了まで | 呼び出し後の結果 | 確定結果 |
|---|---|---|---|---|---|---|
| E（`--cancel-after 1`） | 話し始める前 | 1.030 s | 0.122 s | 0.122 s | 1 件（volatile「。」） | 0 件 |
| F（`--cancel-after 6`） | 話している途中 | 6.084 s | 0.117 s | 0.117 s | 3 件（volatile「…確」「…確認」「…確認。」） | 0 件 |

- 話している途中でも話す前でも、`cancelAndFinishNow()` は約 0.12 秒で戻る
- メモリ（`phys_footprint` の計測中の最大 / プロセス生涯の最大）：E は 6.3 / 6.3 MB、F は 6.3 / 6.4 MB
- キャンセルを呼んだあとにも暫定結果が届く。アプリ側では、キャンセルした時点で以降の結果を捨てる必要がある（アプリの経路〈XPC Worker 経由〉では確かめていない）
- F の話した内容は「これはキャンセルの確認です」で、暫定結果は「俺はキャンセルの確認。」（「これは」→「俺は」）
- E は今回、F と同じファイル名（`mic-cancel.jsonl`）で実行して上書きされたため、ログは F だけ残っている。E の値は標準出力の summary から写した。上の再現コマンドでは、E のログを別のファイルに分けている

## まだ計測していないもの

- 精度の数値評価（`batch` → `utter-eval`。録音ファイルの用意が要る）と、`--preset transcription`（`fastResults` なし）との比較
- オフラインでの認識
- 認識中の OS 側のプロセスのメモリ
- アプリ本体（XPC Worker 経由）での認識
- 話し始めの時刻を外部で測った「初回文字表示」の p95
