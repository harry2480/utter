# Phase 0 検証: Accessibility 挿入の成功率・Undo・クリップボード復元（#41）

## 目的

macOS の Accessibility API による入力欄挿入が以下を満たすことを確認（INS-01, INS-05, AC-20）：
- 主要アプリでの挿入成功率（≥ 95% 目標）
- 成功を確認できるか（読み戻し）
- Undo 挙動の安全性
- クリップボード履歴（Transient 設定）の効果

## テスト環境

- OS: macOS 12.0 以上（Monterey+）
- Accessibility 権限: **有効化必須**（System Preferences → Security & Privacy → Accessibility）
- テスト対象アプリ: Safari, Chrome, Slack, Zoom, TextEdit, Xcode Terminal

## テスト項目

### 1. アプリ別挿入成功率

```
手順:
1. 各アプリで入力欄にフォーカス
2. utter HUD で「Insert」を実行
3. 成功・失敗を記録

期待結果:
- Safari/Chrome: ≥ 95%
- Slack/Zoom: ≥ 90%（複雑な要素）
- IDE/Terminal: ≥ 85%（特殊文字制限あり）

合格基準: 全体 ≥ 95%
```

### 2. 成功確認の可否（INS-05）

```
手順:
1. 挿入実行
2. 入力欄の値を読み戻す
3. 挿入されたテキストと一致確認

期待結果:
✅ Safari, TextEdit: 読み戻し可能（UITextView）
⚠️ Slack, Chrome: 権限制限で読み戻し不可の可能性
❌ Terminal: 読み戻し不可（特殊制御）

記録: アプリ別の成功確認可否表
```

### 3. Undo 挙動（INS-07）

```
手順:
1. 挿入実行後、Cmd+Z（Undo）
2. 挿入されたテキストが削除されるか確認
3. 2回目の Undo で さらに遡行できるか

期待結果:
- 1回の Undo で取り消し可能
- 追加操作なし（Pasteboard 復元不要）

記録: アプリ別 Undo 挙動
```

### 4. クリップボード管理（INS-06）

```
手順:
1. utter がコピー・貼り付けを実行
2. 1Password 等のクリップボード管理アプリで履歴確認
3. Transient フラグ設定の効果を検証

期待結果:
✅ Transient = true で履歴に非表示
✅ Concealed = true で内容マスク

記録: 設定効果の確認
```

## 検証結果テンプレート

### 日時: YYYY-MM-DD, 実施者: XXX

| アプリ | 成功率 | 読み戻し可 | Undo 可 | 備考 |
|-------|-------|----------|--------|------|
| Safari | XX% | ✅/❌ | ✅/❌ | |
| Chrome | XX% | ✅/❌ | ✅/❌ | |
| Slack | XX% | ✅/❌ | ✅/❌ | DM vs Channel |
| Zoom | XX% | ✅/❌ | ✅/❌ | チャット機能 |
| TextEdit | XX% | ✅/❌ | ✅/❌ | Plain text |
| Xcode | XX% | ✅/❌ | ✅/❌ | コードエディタ |
| Terminal | XX% | ✅/❌ | ✅/❌ | 改行制御 |

## Phase 0 Go/No-Go 判定

| 項目 | 基準 | 実測 | 判定 |
|------|------|------|------|
| 全体成功率 | ≥ 95% | XX% | ✅/❌ |
| 読み戻し可アプリ | ≥ 3個 | X個 | ✅/❌ |
| Undo 安全性 | 全て可 | XX% | ✅/❌ |

**全て ✅ で Phase 1 着手許可**

## 次フェーズ

- 成功確認できないアプリの Pasteboard 退避実装（Phase 1, INS-02）
- アプリ別既定経路の決定（AX / Pasteboard / CGEvent）
