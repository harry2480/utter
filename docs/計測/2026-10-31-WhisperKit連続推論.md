# WhisperKit の連続推論での安定性（large-v3 turbo、macOS・2026-10-31）

Phase 0 検証 [#49](https://github.com/harry2480/utter/issues/49) の「連続利用時の熱・電力と、Mac 全体のフリーズ・再起動の有無」の記録。
比べた中でいちばん重い large-v3 turbo（632MB）で、約127秒の音声を約31分のあいだ休まず推論し続けた。

## 条件

- 実行日：2026-10-31（18:30〜19:02）
- 機種：Mac17,2・Apple M5・メモリ 24GB。**バッテリー駆動**（電源につながず、残り約60%）
- OS：macOS 27.0.1（Build 26A434）
- WhisperKit 1.1.1、`--compute default`、`--chunking vad`
- モデル：`openai_whisper-large-v3-v20240930_turbo_632MB`（`argmaxinc/whisperkit-coreml` の main、コミット `0f63a78`。取得とコンパイルは同じ日の先の計測で済んでいる）
- 音声：[合成音声の比較](2026-10-31-合成音声-STT比較.md) の `long.wav`（40件の正解を「。」でつないだ `say -v Kyoko` の音声、126.7 秒）
- ほかのアプリ（ブラウザ・エディタなど）は普段どおり開いたまま

再現のコマンド（リポジトリのルートで実行。`long.wav` の作り方は合成音声の比較の再現手順を参照）：

```sh
wk=Verification/WhisperKitProbe/.build/release/whisperkit-probe
# Mac 全体の熱の警告とメモリの余裕を30秒ごとに記録する
(for i in $(seq 1 70); do echo "$(date +%T) $(pmset -g therm | grep -c 'No thermal warning') $(memory_pressure -Q | tail -1)"; sleep 30; done > "$TMPDIR/system.log" &)
$wk bench --model openai_whisper-large-v3-v20240930_turbo_632MB --audio eval/audio/synthetic/long.wav \
  --runs 270 --interval-ms 1000 --idle-after-s 60 --out "$TMPDIR/wk-endurance"
```

## 結果

| 項目 | 値 |
|---|---|
| 成功 | 270 / 270 回（すべての回で1回目と同じ文字列） |
| 推論時間（126.7 秒の音声） | 中央値 6.84 秒・最小 6.83 秒・最大 6.94 秒（実時間比 0.054） |
| 自プロセスのメモリ（各回のピーク） | 最初の30回は最大 299.5MB、最後の30回は最大 316.1MB |
| 自プロセスのメモリ（各回の終了時） | 1回目 228.2MB、中央値 265.2MB、270回目 264.2MB |
| プロセス開始からの最大（`lifetime_max_mb`） | 321.6MB |
| 推論後に1分待ったとき / アンロード後 | 221.7MB / 32.3MB |
| 熱状態（`ProcessInfo.thermalState`、1秒ごと） | 全区間 `nominal` |
| Mac 全体の熱の警告（`pmset -g therm`、30秒ごと 64回） | 64回とも記録なし |
| Mac 全体のメモリの余裕（`memory_pressure`） | 35〜41% |
| フリーズ・再起動・クラッシュレポート | なし（この時間帯の `/Library/Logs/DiagnosticReports/` に WhisperKit・カーネルパニックの記録なし） |

読み取れること：

- 約31分の連続推論で、速度は1回目から最後まで変わらず（最大と最小の差 0.11 秒）、熱で遅くなる様子はなかった
- メモリは2回目で約290MB に上がったあと、増え続けはしなかった（各回の終了時の値は中央値前後で横ばい）。ピークは最後の30回のほうが約17MB 高いが、終了時の値は増えておらず、リークとは見ていない（推測）
- 長い音声（126.7 秒）では、短い発話（約3秒）を40件流したときの最大 113MB より大きく、約320MB だった。VAD で分割した区間の音声とデコード結果を保持するためと見られる（推測）。それでも目標（1GB 以下）に収まる
- 実時間比は 0.054 で、短い発話の 0.157 より小さい。短い発話では、1回ごとの固定の処理時間の割合が大きいためと見られる（推測）

## 関連して見つけたこと

- 同じ日の先の計測で、large-v3 turbo を初めてロードしたとき（15:26〜15:28、132 秒）、`ANECompilerService` の CPU 使用量の超過の記録（`ANECompilerService_2026-10-31-152826_….cpu_resource.diag`）が残っていた。クラッシュではなく、Neural Engine 向けのコンパイルで CPU を長く使ったという OS の記録。初回ロードを利用者の操作の途中でさせない（取得後にバックグラウンドで済ませる）設計が要る

## 測れていないこと

- 消費電力：`powermetrics` は管理者権限が要るため、今回は測っていない。電池の減りは、ほかのアプリも動いていたので WhisperKit の分を切り分けられない
- 電源につないだ状態との違い、ファンのない機種（MacBook Air）での熱
- base・small での連続推論（turbo より軽いので、turbo で問題がなければ問題になりにくいと見ている。推測）
- アプリに組み込んだ状態（XPC Worker 経由）での連続利用
