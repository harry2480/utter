# Phase 0 検証: Accessibility 挿入の成功率・Undo・クリップボード復元（#41）

## 環境

- **OS**: macOS 26.0 以降（Apple Silicon）
- **権限**: システム設定 → プライバシーとセキュリティ → アクセシビリティ（有効化必須）
- **テスト用文字列**: 固定のダミー文字列のみ使用。機密情報は使わない

## 検証目的

主要アプリでの Accessibility 挿入について：
- 成功可否とその理由
- 成功確認可否（読み戻し）
- Undo 安全性
- クリップボード復元安全性

の4項目を測定し、各アプリの**既定経路（AX / Pasteboard / CGEvent / プレビュー退避）** を決定する（AC-20, INS-01-07）。

## テスト手順

### 1. 検証ハーネス準備

Phase 0 には HUD がないため、CLI の検証ハーネスを使う（当初案の `./verify-accessibility [app-name] [insertion-method]` は採用せず、下記に置き換えた）。

検証ハーネスは [Verification/AXInsertionProbe/](../Verification/AXInsertionProbe/README.md) にある（`ax-insertion-probe run --route ax-selected|ax-value|pasteboard|cgevent`）。ビルド・権限・記録の列・片付けは同 README に従う。

### 2. アプリ・入力欄別テスト

対象アプリと入力欄の種類（経路別）:

| アプリ | 入力欄種別 | 経路 | N 試行 |
|-------|----------|------|--------|
| Safari | `<input type="text">` | AX, Pasteboard | 20+ |
| Safari | contenteditable | AX | 20+ |
| Chrome（Chromium） | `<input>` | AX* | 20+ |
| Slack (Electron) | メッセージ欄 | Pasteboard | 20+ |
| TextEdit | NSTextView | AX | 20+ |
| Terminal.app | ターミナル | Pasteboard+ | 20+ |
| Xcode | ソースエディタ | AX, Pasteboard | 20+ |
| Zoom | チャット欄 | Pasteboard | 20+ |

\* Chrome: `AXEnhancedUserInterface` 有効化が前提
\+ Terminal: Enter が自動送信されないことが必須（INS-03）

### 3. 成功定義

```
成功 = 以下のいずれか:
- 読み戻しで完全一致
- 目視で完全一致
- ❌ 失敗 = 挿入されない / 一部欠落 / 誤文字
- ❓ 成功不明 = 挿入は見えるが確認不可（権限制限など）
```

### 4. 記録テンプレート

下の表の行は書き方を示す記入例で、値は架空である。実測の結果ではない。

```
日時: YYYY-MM-DD, OS build: XX.0.XXXXX, 実施者: XXX

| アプリ | Ver | 入力欄 | 経路 | N | 成功数 | 成功% | 読み戻し | Undo | 失敗理由 | 既定経路 |
|--------|-----|--------|------|---|--------|-------|----------|------|---------|----------|
| Safari | 17.X | <input> | AX | 20 | 19 | 95% | 可 | 1回可 | AX接続失敗1件 | AX |
| Chrome | 120 | <input> | AX* | 20 | 0 | 0% | 不可 | N/A | TreeDisabled | Pasteboard |
| Terminal | 3.X | ターミナル | Paste | 20 | 18 | 90% | 不可 | 不可 | 改行が Enter | Pasteboard |
```

### 5. 異常系テスト（INS-01, INS-03）

```
✓ フォーカス移動: 挿入前に別ウィンドウへ移動 → 対象アプリへ挿入しない
✓ ウィンドウ消失: 挿入前にウィンドウを閉じる → 挿入しない
✓ パスワード欄: Secure 入力欄では挿入しない
✓ Terminal: Enter を含む文字列を挿入 → 改行として送信されない
✓ 二重挿入防止: キーボードのダブルクリックで再挿入なし（短時間での重複実行）
```

### 6. クリップボード復元テスト（INS-04, INS-06）

```
手順:
1. 元のクリップボード（画像またはファイル）を設定
2. 挿入実行（Pasteboard 経路）
3. 挿入完了後、元のクリップボードを復元
4. Maccy / Raycast / Alfred で履歴確認

期待:
✅ 復元されたデータは変わらない（種類・内容）
✅ Transient / Concealed フラグの有効性を記録
❓ 別アプリが挿入中にクリップボードを更新した場合の安全性
```

## Go/No-Go 判定

**判定目的**: アプリ別の既定経路を決定し、成果物 AC-20（互換性表）を完成させる

**No-Go になるのは**:
- 主要対象アプリ（Safari, Chrome, Slack）が全て失敗
- 読み戻し・Undo の両方が不可なアプリが 3 個以上

**それ以外は Go** → 失敗したアプリは Pasteboard / プレビュー退避を既定経路とする

## 成果物（AC-20 互換性表）

この検証の記録から決めたアプリ × 入力欄ごとの既定経路・判定・既知の制限は、[挿入互換性表.md](挿入互換性表.md) に書く。列の定義、判定基準（成功／条件付き／非対応）、記入手順は同書に従う。
