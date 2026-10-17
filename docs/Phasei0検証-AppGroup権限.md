# Phase i0 検証: App Group・個人署名・キーボードのフルアクセス（#56）

## 目的

iOS キーボード拡張と本体アプリ間の IPC（プロセス間通信）の実現可否を確認：
- App Group（Shared Container）でのファイル共有（iOS-IPC-04）
- 個人開発者による署名・プロビジョニング（限定配布可否）
- キーボード拡張のフルアクセス権（Full Access）要件

## 確認項目

### 1. App Group コンテナ（Shared Container）

```
構成:
- 本体アプリ と キーボード拡張が同じ App Group に属する
- 構成ファイル: Xcode target の "Signing & Capabilities"

実装可否:
✅ App Group Container URL を共有
✅ FileManager でアクセス可能
✅ 権限なしで読み書き可（同一 Team ID）
```

### 2. 個人開発者署名

```
要件:
- Apple Developer Program 登録（年額 $99）
- Certificate（個人開発者用）
- Provisioning Profile（ad hoc, development）

実装可否:
⚠️ Mac App Store 配布は不可（企業アプリ原則）
✅ GitHub Releases での直配布可（署名・公証済 pkg）
✅ 自動更新（Sparkle 2）で管理可能

制約:
- 有効期限：3年（Certificate）/ 1年（Provisioning Profile）
- Team ID は個人デバイスのみで変更不可
```

### 3. キーボード拡張のフルアクセス権

```
ユーザーへの要求:
1. Settings → General → Keyboard → Keyboards
2. utter Keyboard 選択 → "Allow Full Access" を ON

技術的な制約:
- Full Access なしでも UITextDocumentProxy は使用可
- ただし、高度な入力欄制御には Full Access 必須（INS-05）
- URL スキームでの本体アプリ起動は Full Access 不要

実装指針:
✅ 本体アプリ URL スキーム（utter://）で連携
✅ Keychain（App Group 対応）で認証情報共有
✅ Full Access 要求は段階的（初回キーボード使用時）
```

### 4. 配布方式の選択肢

| 方式 | App Group | 個人署名 | フルアクセス | 配布形式 |
|------|----------|--------|----------|--------|
| **Mac App Store** | ✅ | ❌ | N/A | Store 経由 |
| **GitHub 直配布** | ✅ | ✅ | ✅ | pkg（署名済） |
| **TestFlight** | ✅ | ❌ | ✅ | App Store Connect |

**utter 方針：** GitHub 直配布（個人 OSS）

## 実装チェックリスト

- [ ] Xcode: 本体 + キーボード拡張のターゲット設定
- [ ] Team ID 統一（本体・拡張・App Group）
- [ ] Signing Certificate 作成（個人開発者）
- [ ] Provisioning Profile 生成（キーボード拡張用）
- [ ] App Group Identifier 統一確認
- [ ] Keychain Access Group 設定（認証情報共有）
- [ ] URL Scheme 登録（utter://）

## 次フェーズ

- Xcode プロジェクト設定（Phase i1 実装）
- TestFlight vs GitHub 直配布の最終決定（Phase 2）
