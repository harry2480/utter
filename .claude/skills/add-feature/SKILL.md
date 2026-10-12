---
description: 新しい機能を追加する。ユーザーが機能や要件ID（REC-01 等）を指示したとき、モジュール構成に従って Package とアプリ側のファイルを生成する
---

# 機能追加スキル

ユーザーが「〇〇な機能を作って」「REC-05 を実装して」と指示したときに適用する。

## 手順

1. **要件の特定** — [docs/要件定義.md](../../../docs/要件定義.md) から対象の機能ID・受け入れ基準を特定する。要件にない機能なら、実装前に要件定義への追記を提案する
2. **配置の決定** — [docs/アーキテクチャ.md](../../../docs/アーキテクチャ.md) のモジュール責務に従い、共通ロジックは `Packages/`、OS 固有 API は `Apps/` / `Extensions/` / `Workers/` に置く
3. **ファイル生成**（必要なものだけ）
   - モデル・状態: `Packages/UtterCore/Sources/UtterCore/{Type}.swift`
   - protocol と実装: 該当 Package の `Sources/{Module}/{Type}.swift`
   - 外部 API・STT を使う場合: protocol + 本番実装 + `Stub{Role}` の3点セット（`add-api-integration` スキル参照）
   - OS 固有アダプター: `Apps/macOS/...` / `Apps/iOS/...`。protocol は Package 側に置く
   - DI の組み立て: 各アプリの起動部（Composition Root）
4. **テスト** — `Packages/{Module}/Tests/{Module}Tests/{Type}Tests.swift` に Swift Testing で書く。表示名に機能IDを入れる
5. **検証** — `scripts/verify.sh` を実行して全パスすることを確認する。実機確認が必要な項目は、確認手順をユーザーに提示する

## Package が未作成の場合

対象の Package がまだなければ、`Packages/{Module}/Package.swift` を作成する。

- `swift-tools-version` は 6.0 以上、`swiftLanguageModes: [.v6]`
- `platforms: [.macOS(.v26), .iOS(...)]`（iOS の最低バージョンは Phase i0 の結果に従う。未確定ならユーザーに確認する）
- 依存は UtterCore への local path 依存から始める

## ルール

- UtterCore は Foundation 以外に依存しない
- Keyboard Extension に録音・STT モデル・クラウド認証を持たせない
- 発話本文・音声・秘密情報をログやエラー文言に出さない
- クラウド送信を伴う機能は同意状態を確認する経路を必ず通す
- strict concurrency の警告を `@unchecked Sendable` 等で黙らせない
