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

## 検証用アプリでの確認手順と記録

上の「確認項目」「配布方式の選択肢」の記述は検証前の想定で、未確認のものを含む。結論は以下の実機の記録で確定する。

検証用アプリ: [Verification/iOSKeyboardProbe/README.md](../Verification/iOSKeyboardProbe/README.md)（ビルド・インストール・画面の見方・片付け）

### 手順

1. README の「実機へのインストール」に従い、まず**無料 Personal Team** でインストールする。署名・プロビジョニングのエラーが出たら、その文面を記録 A に残す（不可なら有料 Developer Program で同じ手順を繰り返し、両方を記録する）
2. 本体アプリで「全保護クラスで書き込む」→ 各クラスの「実際の保護属性」を記録 B に残す
3. キーボードを追加し、**フルアクセス無効**のまま、メモ等の通常の入力欄で utter Probe キーボードに切り替えて「読む」「書く」「挿入」を押し、記録 C に残す
4. 設定でフルアクセスを**有効**にして、3 を繰り返す
5. 本体アプリで「ロック中の読み書き」を待ち時間 20 秒で開始 → すぐにロック → 30 秒ほど待って解除 →「記録をコピー」の内容から記録 D を埋める
6. 本体アプリで「プローブのファイルをすべて削除」

### 記録 A: 署名と App Group の Entitlement

| 署名 | 日付 | Xcode | iPhone / iOS | インストール可否 | App Group のコンテナ URL | エラー文（あれば） |
|---|---|---|---|---|---|---|
| 無料 Personal Team | | | | | | |
| 有料 Developer Program（必要時） | | | | | | |

### 記録 B: 書き込み時に付いた保護属性

| 保護クラス | 書き込み | 実際の保護属性 |
|---|---|---|
| complete | | |
| completeUnlessOpen | | |
| completeUntilFirstUserAuthentication | | |
| none | | |

### 記録 C: キーボード拡張からの読み書き（ロック解除中）

| フルアクセス | hasFullAccess 表示 | コンテナ URL | 読む（クラスごとの成否・エラー） | 書く | 挿入（共有結果 / 固定ダミー） |
|---|---|---|---|---|---|
| 無効 | | | | | |
| 有効 | | | | | |

### 記録 D: ロック中の本体アプリの読み書き（iOS-IPC-05）

| 保護クラス | 読み込み（成否・エラー） | 新規書き込み（成否・エラー） |
|---|---|---|
| complete | | |
| completeUnlessOpen | | |
| completeUntilFirstUserAuthentication | | |
| none | | |

実行時の `isProtectedDataAvailable`: ／ 残りのバックグラウンド実行時間: ／ 打ち切られたか:

### 結論（14章の判定）

- App Group と個人署名: （無料で可 / 有料が必要 / 不可 → iOS MVP 保留）
- キーボードのフルアクセス: （不要 / 必要。必要なら理由）
- 共有結果の保存方式（iOS-IPC-01, 04）と保護クラス: 
