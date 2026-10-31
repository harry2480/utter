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

## 記録

### 2026-10-31（macOS 27.0.1（26A434）、Mac17,2・Apple M5、Claude Code による自動実行）

`AXInsertionProbe` を、操作を自動化するスクリプトから実行した（人の目視・クリップボード管理アプリの確認なし）。入力ソースは ABC（日本語入力オフ）、文字列は `--text ja`、各経路20回（`--interval 0.5`）。対象は検証用の新しい文書と、ローカルの検証用ページ（`<input type="text">`・`<textarea>`・`contenteditable` の `<div>` を1つずつ置いたもの）だけ。

| アプリ | Ver | 入力欄 | 経路 | N | 成功数 | 成功% | 読み戻し | Undo（⌘Z 1回） | 失敗理由 | 既定経路 |
|--------|-----|--------|------|---|--------|-------|----------|------|---------|----------|
| TextEdit | 1.21 | NSTextView | AX | 20 | 20 | 100% | 可（range） | 挿入分だけ取消 | ― | AX |
| TextEdit | 1.21 | NSTextView | Pasteboard | 20 | 20 | 100% | 可（range） | 挿入分だけ取消 | ― | |
| TextEdit | 1.21 | NSTextView | CGEvent | 20 | 20 | 100% | 可（range） | 挿入分だけ取消 | ― | |
| Safari | 27.0.1 | `<input>`・`<textarea>`・contenteditable | AX | 各20 | 0 | 0% | 可（変化なしを確認） | ― | 書き込みは成功を返すが値が変わらない（`failed`） | |
| Safari | 27.0.1 | 同上 | Pasteboard | 各20 | 20 | 100% | 可（range） | 挿入分だけ取消 | ― | Pasteboard |
| Safari | 27.0.1 | 同上 | CGEvent | 各20 | 20 | 100% | 可（range） | **挿入より多く取り消す** | ― | |
| Chrome | 156.0.8078.48 | `<input>`・`<textarea>`・contenteditable | AX | 各20 | 0 | 0% | 可（変化なしを確認） | ― | 同上（`failed`） | |
| Chrome | 156.0.8078.48 | 同上 | Pasteboard | 各20 | 20 | 100% | 可（range） | 挿入分だけ取消 | ― | Pasteboard |
| Chrome | 156.0.8078.48 | 同上 | CGEvent | 各20 | 20 | 100% | 可（range） | **挿入より多く取り消す** | ― | |

- Pasteboard 経路は全 140 回でクリップボードを復元できた（`restore=restored`）。挿入開始から読み戻しの一致までは中央値 55ms（最大 121ms）。AX は 6.5ms、CGEvent は 255ms（1文字ずつ送るため）
- AX 経路の Safari・Chrome は、`kAXSelectedTextAttribute` の書き込みが成功を返すのに値が変わらなかった。読み戻しで「変化なし」と確かめられるので、`InsertionResult.classify` は `failed`（挿入されていないことが確か）とし、次の経路（Pasteboard）へ進める。誤った挿入にはならない
- **CGEvent 経路の Undo（Safari・Chrome）**：直前の CGEvent の試行で入れた文字列とまとめて1つの取り消し単位になり、⌘Z 1回で挿入より多く（直前の連続した試行の分まで）消えた。キー入力として扱われるため、利用者が直前に打った文字とも同じ単位になる可能性がある（推測）。TextEdit では挿入分だけが消えた
- Undo は、各経路の連続試行の後に1回だけ挿入し、⌘Z を1回送って、値が挿入前に戻るかを見た（`osascript` で ⌘Z を送り、System Events で値を読む）
- Chrome は1回目の計測で、全試行が `no-focus`（フォーカス中の要素を取れない）になった。`AXEnhancedUserInterface` を設定しようとした（`AXUIElementSetAttributeValue` は -25208 を返した）あとの2回目では、追加の設定なしで要素を取れた。Chrome が支援技術からの問い合わせを受けて AX ツリーを作るまで時間がかかるためと見られる（推測）。表は2回目の結果
- **macOS 27.0.1 でのフォーカスの取得**：システム全体の要素（`AXUIElementCreateSystemWide()`）に `AXFocusedUIElement`・`AXFocusedApplication` を問い合わせると、`kAXErrorCannotComplete`（-25204）が返った。最前面アプリの要素（`AXUIElementCreateApplication(pid)`）への問い合わせは成功した。Probe は NSWorkspace の最前面アプリから取る代替を足して計測した。本体アプリの `AccessibilityInsertionTarget.focusedElement()` も同じ問い合わせをしているため、アプリでも起きるかを確かめる必要がある（RunLoop を回すアプリでは起きない可能性もある。未確認）

未実施（人の確認が要る）：

- Slack・Discord・Xcode・Zoom・ターミナル（送信や実行が起きうるため、検証用のチャンネル・文書を人が用意して確かめる）
- クリップボード管理アプリの履歴（INS-06。Transient / Concealed の印の効果）
- 異常系（フォーカス移動・ウィンドウ消失・パスワード欄・ターミナルの改行・二重挿入）
- 日本語入力オンでの CGEvent 経路
