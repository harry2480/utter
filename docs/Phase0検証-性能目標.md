# Phase 0 検証: 速度・待機メモリ・バッテリー目標の現実性（#52）

## 目的

utter の Phase 0 成功判定基準となる非機能要件を確定：
- 起動時間（REC-02）
- 待機時メモリ（REC-05）
- 連続使用時のバッテリー消費

## 性能目標（案）

### 1. 起動時間

```
目標:
- アプリ起動（メニューバー表示）: < 2秒
- モデル初回取得（5-10分）は許容
```

### 2. 待機メモリ

```
目標:
- メニューバー常駐状態: < 50MB（アイドル）
- EventMonitor 有効時: < 100MB
- バッファ予約（AudioStreamBuffer): ≤ 10MB（デフォルト）

参考:
- Slack: ~200-300MB
- 1Password: ~100-150MB
```

### 3. バッテリー消費

```
目標:
- 待機状態での追加消費: < 2%/時間
- 連続認識時の消費: < 5%/時間（ローカル STT）
- クラウド AI 利用時: < 3%/時間（ネットワーク有効）
```

## 計測方法

### メモリ計測

```bash
# Instruments（Activity Monitor）で実機計測
- Physical Memory（実メモリ）
- Virtual Memory（仮想メモリ）
- Resident Set Size（RSS）

手順:
1. アプリ起動後 5 分待機
2. ピークメモリを記録
3. EventMonitor ON で再計測
```

### バッテリー計測

```
手順:
1. 満充電状態から開始
2. 4時間待機 → バッテリー % 記録
3. 平均消費率を計算

例: 100% → 92% = 8% × 4時間 = 2%/時間 ✅
```

### 計測ツールと Signpost 区間名

区間計測（`xctrace` の記録と p50/p95 の集計）、メモリ・CPU のサンプリング、8時間待機のバッテリー記録の道具と使い方は [Verification/PerfProbe/README.md](../Verification/PerfProbe/README.md)。集計は要件定義6章の目標値と並べて出す。

Signpost はサブシステム `utter.perf`、カテゴリ Points of Interest で発行する。区間名は `Verification/PerfProbe/Sources/PerfProbe/PerfInterval.swift` と一致させる。
macOS アプリは同じ区間名を `Apps/macOS/Sources/Performance/PerfInterval.swift` に持ち（アプリは使い捨ての PerfProbe に依存しない）、一致は `UtterMacTests` で確かめる。

| 区間名 | 開始 → 終了 |
|---|---|
| `RecordingStart` | 録音開始の操作 → 最初の音声バッファ受信（録音開始遅延） |
| `RealtimeFirstText` | 録音開始の操作 → Realtime Preview の初回文字表示 |
| `STTFinalize` | 録音停止 → STT の確定結果 |
| `LLMFirstToken` | LLM への要求送信 → 初回トークン |
| `LLMComplete` | LLM への要求送信 → 応答完了 |
| `Insert` | 挿入開始 → 挿入完了 |
| `StopToInsertLocal` | 録音停止 → 挿入完了（ローカル高速入力） |
| `StopToInsertAI` | 録音停止 → 挿入完了（AI整形あり） |
| `ModelLoad` | STT モデルのロード開始 → 完了（コールドスタートの内訳） |

### macOS アプリでの計測（#52）

macOS アプリ（`Apps/macOS`）は上の区間名で Signpost を出す。区間には名前だけを付け、発話本文・アプリ名・bundle ID・ファイル名などのメッセージは載せない。出すのはローカルの OS ログだけで、送信しない。

**常に出す（ビルド構成・起動引数で切り替えない）。** Points of Interest は Instruments・xctrace が記録している間だけ有効になるカテゴリで、記録していなければ Signpost は有効かを確かめるだけで戻り、ほぼ無コスト。区間を出すのは録音のセッションの間だけで、待機中は1つも出さない（待機時 CPU・バッテリーに影響しない）。名前しか載せないためプライバシー上の差もない。常に出しておくと、6章の計測に向く Release 構成（最適化あり）のアプリをそのまま計測できる。起動引数の有効化は Debug ビルドに限られ（他の `-UtterDebug…` と同じ）、Release を測れなくなるため使わない。

手順:

1. `Config/Local.xcconfig` で `UTTER_MAC_STT_ENGINE = speechAnalyzer` を有効にし（Release は起動引数の `-UtterDebugSTTEngine` を読まない）、設定画面の「音声認識」タブでモデルを取得しておく
2. `scripts/build-local.sh` で Release 構成をビルドし、`build/local/DerivedData/Build/Products/Release/utter.app` を起動する（[ビルド・配布規約.md](ビルド・配布規約.md)）。Debug 構成は最適化がないため、6章の目標との比較には使わない
3. アプリのプロセス名は `utter`（STT Worker は別プロセスの `UtterSTTWorker` で、区間は出さない）。記録中に発話→停止→挿入を条件ごとに 20 回以上繰り返す

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd Verification/PerfProbe
scripts/record-signposts.sh --label local-builtin-mic-01 --attach utter --time-limit 15m
# 同名のプロセスが複数あるとき（Xcode から起動した Debug ビルドが残っているなど）は PID を渡す
scripts/record-signposts.sh --label local-builtin-mic-01 --attach "$(pgrep -x utter)" --time-limit 15m
```

- ローカル高速入力（`StopToInsertLocal`）は、設定画面で整形の処理系を Local Basic（既定）にして測る。AI 整形あり（`StopToInsertAI`）は、処理系を Claude にして同意・API キー・月次予算と単価表をそろえ、別の `--label` で測る
- `RealtimeFirstText` は入力モードを Realtime Preview にしたときだけ出る（Instant と Realtime Direct では出さない）
- 計測中はキャンセルしない。キャンセル・失敗・録音の抑止（機密入力）で終わったセッションは、終点に達しないまま区間をその時点で閉じるため、短い値が集計に入る（下の「区間の開始・終了の位置」）。HUD に失敗・キャンセルが出た回があれば、その trace は取り直す

区間の開始・終了の位置（`SessionCoordinator` と `SessionRefinementPipeline`。録音のセッションだけを測り、Edit Mode・起動時の復旧は測らない）:

| 区間名 | 開始 | 終了 | 出さない場合 |
|---|---|---|---|
| `RecordingStart` | `SessionCoordinator.startRecording()` で、STT の有無を確かめた直後・入力対象の記録と機密入力の判定より前。ショートカットのハンドラ（Carbon のホットキー・イベントタップ）とメニューの操作から同期的に呼ばれるため、イベントを受けた時点とみなせる（それより前の、待機中かの確認と設定の読み出し1回は入らない） | 録音の最初の音声チャンクを MainActor の転送タスクが受け取った時点（録音側のモノラル化・リサンプル・チャンク分割の後）。クラウド STT のセッションでは、録音を始める前の同意・API キー・予算の確認も区間に入る | 音声認識が未設定（マイクを開かない） |
| `RealtimeFirstText` | `RecordingStart` と同じ時点（入力モードが Realtime Preview のときだけ） | 確定済みか暫定のテキストが空でない最初の認識イベントを HUD に渡した時点 | Instant・Realtime Direct |
| `STTFinalize` | 状態が録音から認識へ進んだ時点（停止の操作・最大録音時間・音声バッファの上限・割り込みのどれでも。認識が録音中に先に終わった場合は、その後の停止の時点） | 挿入する本文の元になる確定結果がそろった時点（STT Worker の異常終了で録音全体を認識し直した場合は、認識し直した結果） | — |
| `LLMFirstToken` | — | — | 出さない。Claude への整形はストリームで受け取らず（`ClaudeProvider` は応答全体を1回で受け取る）、初回トークンの時点がない |
| `LLMComplete` | `RefinementRouter` が同意・機密入力・予算の予約を確かめた後に送信先の `refine` を呼ぶ時点（`PerfMeasuredAIProvider`）。API キーの読み出しと要求の組み立ても入る | `refine` が戻った時点（応答の検証は入らない）。失敗・上限時間の超過・キャンセルでも、戻った時点で閉じる。区間の開始・終了で MainActor へ切り替える分も入る | 送らなかったセッション（Local Basic・Raw・同意なし・機密入力など） |
| `Insert` | 挿入（`SessionTextInserting.insert`）を呼ぶ直前 | 挿入が戻った時点（読み戻しの確認・プレビューへの退避を含む） | Realtime Direct で書き込んだセッション（一括挿入しない） |
| `StopToInsertLocal` / `StopToInsertAI` | `STTFinalize` と同じ時点。どちらにするかはその時点の設定で決める（処理系が Claude で整形モードが Raw でなければ AI）。同意・API キー・予算がそろわずローカルへ退避した回も AI 側に入るため、AI 整形ありを測るときは条件をそろえる | 挿入が戻った時点（`Insert` の終了の直後） | クラウド STT のセッション（ローカル高速入力ではない）、Realtime Direct を使えたセッション |
| `ModelLoad` | — | — | 出さない。SpeechAnalyzer はモデルを OS が管理し、STT Worker の `SpeechModelLoader.load()` はモデルを読み込まない（読み込みは OS のプロセスで認識の中に起きる）。WhisperKit を Worker に登録したら、Worker のロードの前後で出す |

- 区間が終点に達しないままセッションが終わったら（キャンセル・失敗・録音の抑止・Realtime Direct などの別経路）、待機・失敗の表示へ進んだ時点で開いている区間をすべて閉じ、開いたままの区間を残さない。Signpost にはメッセージを付けないため、閉じ方は trace から区別できない
- STT Worker・Edit Mode・起動時の復旧は区間を出さない。待機時のメモリ・CPU・バッテリーは区間ではなく `sample-process.sh` / `battery-log.sh` で測る（[Verification/PerfProbe/README.md](../Verification/PerfProbe/README.md)）

## Phase 0 Go/No-Go 判定

| 項目 | 目標 | 実測 | 判定 |
|------|------|------|------|
| 起動時間 | < 2s | XXs | ✅/❌ |
| 待機メモリ | < 50MB | XXmb | ✅/❌ |
| バッテリー消費 | < 2%/h | X%/h | ✅/❌ |

**全て ✅ で Phase 1 着手許可**

## 最適化の優先度

1. **メモリ**: バッファサイズ・モデルキャッシュを削減
2. **CPU**: EventMonitor の精度調整（無駄なイベント削減）
3. **バッテリー**: ネットワーク通信の最小化（WiFi 優先）
