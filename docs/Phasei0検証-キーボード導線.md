# Phase i0 検証: キーボードから本体アプリへの導線と復帰（#53）

## 目的

iOS キーボード拡張での入力フロー確認：
- キーボード → 本体アプリへの戻り方（iOS-03）
- 元の入力欄への自動復帰（INS-06）
- UX 検証

## 実装パターン

### パターン A: URL Scheme での本体起動

```swift
// キーボード内での本体起動
URL(string: "utter://open-keyboard-settings")?.open()
```

**利点:**
- ✅ App Group 不要
- ✅ Cross-app navigation 標準

**課題:**
- ❌ 元の入力欄への自動復帰不可（アプリが異なるため）

### パターン B: App Group + Shared Container

```swift
// キーボード → 本体でハンドシェイク
let appGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.utter")
```

**利点:**
- ✅ 状態共有で復帰可能

**課題:**
- ⚠️ Full Access 要件（複雑化）

## UX 検証項目

| 項目 | 期待 | 検証方法 |
|------|------|--------|
| キーボード → 本体切り替え | スムーズ | 手動操作テスト |
| 入力欄復帰 | 自動復帰 or 手動選択 | 複数アプリ（Safari等）でテスト |
| 違和感なし | UX 評価 | ユーザーテスト |

## Phase i1 での決定

- URL Scheme のみ（シンプル）vs App Group 活用（高度）
- ユーザーフローの最適化

**推奨: URL Scheme + 手動復帰（初期版）**
