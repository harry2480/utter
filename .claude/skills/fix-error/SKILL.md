---
description: エラーを修正する。エラーメッセージから原因を特定し、アーキテクチャルールに従って修正する
---

# エラー修正スキル

ユーザーがエラーメッセージを貼り付けて「直して」と指示したときに適用する。

## 手順

1. **エラーメッセージを解析** — エラーの種類と発生箇所（Package / アプリターゲット / CI）を特定
2. **原因を特定** — コードを読んで根本原因を調査
3. **修正を実施** — アーキテクチャルールに違反しない形で修正
4. **検証** — `scripts/verify.sh` で全チェックがパスすることを確認

## よくあるエラーと対処

### Swift 6 の並行処理エラー（Sendable / actor 隔離）
- 状態を持つ型は `actor` か `@MainActor` に隔離する
- `@unchecked Sendable`、`nonisolated(unsafe)`、`@preconcurrency` で黙らせない。どうしても必要なら理由をコメントに残してユーザーに確認する

### 依存方向違反（モジュールが見つからない / 循環依存）
- 依存方向: `Apps / Extensions / Workers → 各 Package → UtterCore`
- UtterCore から AppKit / UIKit / AVFoundation を import している場合 → protocol を Package に置き、実装を Apps 側に移す
- Package 同士の横依存が必要に見える場合 → 共通の型を UtterCore に移せないか先に検討する

### swift format lint エラー
- `scripts/format.sh` で自動修正

### 権限・署名エラー（実行時）
- Accessibility / マイクの許可が外れた: 署名が変わると再許可が必要。コード修正ではなく、ユーザーにシステム設定での再許可を案内する
- App Group / Entitlement のエラー: `Local.xcconfig` の Team ID・識別子と、ターゲットの Entitlement を確認する

### CI のみで失敗する
- ランナーの Xcode / macOS バージョン差を確認する（`xcodebuild -version` の出力）
- 署名・secret が必要な失敗はコードで回避しない

## ルール

- 修正時もアーキテクチャルール（依存方向、命名規約）とプライバシールールを守る
- エラー調査のために発話本文・トークンをログ出力するコードを追加しない
- 修正後は必ず `scripts/verify.sh` を実行
- エラーの根本原因を修正する（場当たり的な回避策は避ける）
