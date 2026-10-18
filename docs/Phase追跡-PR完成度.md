# Phase 追跡: PR マージ完成度

各 Phase の実装完了判定基準：**前フェーズの全 Issue が Codex 再レビュー・修正・マージ完了**

## Phase 0 （現在）

### ✅ 完全完了（マージ可）
- Issue #45（AppSettings）- PR #76
- Issue #44（DictionaryStore）- PR #79
- Issue #55（SharedResult）- PR #78

### ⏳ 修正待ち
- Issue #40（AudioBuffer）- PR #77：Codex 再レビュー待ち

### ⏳ 検証待ち
- Issue #41, #47-#63：検証ドキュメント完成・実機テスト待ち

---

## Phase 1 ブロッキング条件

**Phase 1 着手前に以下が必須：**
- [ ] Phase 0 の全 PR (#76-#89) がマージ完了
- [ ] Issue #40 が Codex 再レビュー・修正完了
- [ ] Issue #41 が実機検証完了

### Phase 1 PR 一覧（予定）
- 録音・HUD・Instant/Realtime Preview（REC-01, REC-02, REC-06）
- STT Worker（macOS）
- 安全な挿入（INS-01, INS-02, INS-03, INS-04, INS-05, INS-07）
- 設定 UI（ホットキー、スタイル選択）

---

## Phase 2 ブロッキング条件

**Phase 2 着手前：**
- [ ] Phase 1 の全 PR がマージ完了
- [ ] Accessibility 検証完了（#41）

### Phase 2 PR 一覧（予定）
- Claude / ChatGPT プロバイダー実装（AI-01, AI-06）
- 辞書機能（TXT-03）
- アプリ別文体・費用・同意管理（CTX-01, CTX-02, AI-05, AC-06）

---

## Phase 3 ブロッキング条件

**Phase 3 着手前：**
- [ ] Phase 2 の全 PR がマージ完了

### Phase 3 PR 一覧（予定）
- 最適化（メモリ、バッテリー、レイテンシ）
- 障害復旧（キャッシュ、Keychain、エラーハンドリング）
- OSS ビルド・署名・公証

---

## Phase 4 ブロッキング条件

**Phase 4 着手前：**
- [ ] Phase 3 の全 PR がマージ完了

### Phase 4 PR 一覧（予定）
- Edit Mode
- クラウド STT（OpenAI Whisper）
- 履歴機能
- Realtime Direct（MVP 外）

---

## iOS Phase（並行）

### i0（技術検証）
- [ ] App Group・キーボード権限・署名確定

### i1（基本実装）
- [ ] 本体アプリ（録音・STT・整形・結果保存）
- [ ] キーボード拡張

### i2（共有結果・UX）
- [ ] IPC ハンドシェイク
- [ ] キーボード → 本体導線

### i3（互換性・最適化）
手順: [Phasei3検証-実機継続利用.md](Phasei3検証-実機継続利用.md)（#63）

- [ ] メモリ・電力測定
- [ ] iOS バージョン互換性確認

---

## マージチェックリスト（各 PR）

### 対象
- [ ] コード完成度（レビュー完了）
- [ ] Codex レビュー完了・修正反映
- [ ] テスト実行（100% パス）
- [ ] CI パス（lint, build, test）
- [ ] ドキュメント更新
- [ ] PR 説明が要件定義を満たしている

### マージ前の最終確認
- [ ] 前フェーズの全 PR が既にマージ済み
- [ ] ブロッキング Issue なし
