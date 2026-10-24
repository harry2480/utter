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
