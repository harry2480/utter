# utter

macOS ネイティブの音声入力アプリ（OSS）と、共通基盤を使った iOS 個人利用版。
製品要件はすべて [docs/要件定義.md](docs/要件定義.md) が正。機能ID（`REC-*` / `TXT-*` / `INS-*` / `AI-*` / `iOS-*` / `AC-*` / `iAC-*`）で参照する。

## 使い方（利用者向け）

- `scripts/verify.sh` で品質チェック（変更後に実行）
- macOS アプリ本体は `xcodegen generate --spec Apps/macOS/project.yml` で `Apps/macOS/Utter.xcodeproj` を生成し、Xcode で開いてビルドする（署名の設定は `Config/Local.xcconfig.example` を `Config/Local.xcconfig` にコピーして書き換える。手順は [docs/ビルド・配布規約.md](docs/ビルド・配布規約.md)）
- iOS アプリ本体は同様に `xcodegen generate --spec Apps/iOS/project.yml` で `Apps/iOS/Utter.xcodeproj` を生成する（`Config/Local.xcconfig` を共有）
- 機能を追加したいときは Claude Code に「REC-01 を実装して」「〇〇な機能を作って」と指示する
- エラーが出たらエラーメッセージを貼り付けて「直して」と指示

### コマンド一覧

```sh
scripts/verify.sh        # swift format lint → Swift Package build/test → アプリの署名なし xcodebuild（macOS build/test・iOS Simulator build）→ shellcheck
scripts/format.sh        # swift format で自動整形
scripts/coverage.sh      # カバレッジ計測（coverage/*.lcov、CI で Codecov へ送信）
scripts/merge-pr.sh [PR] # PR をマージコミットでマージしてブランチ削除（squash 禁止）
scripts/loop-once.sh     # Loopを1回だけ実行
scripts/loop.sh          # 最大5回までLoopを反復（LOOP_MAX_ITERATIONSで調整）
```

Loopを使う場合は [docs/loop-engineering.md](docs/loop-engineering.md) の初期設定、Issue信頼境界、auto-merge条件に従う。Loop関連コマンドは `.claude/commands/loop-*.md` に定義する。

---

## Claude Code への指示（利用者は読まなくてOK）

### 出力言語

- 応答・作業中の説明・PR/コメントへの返信は日本語。
- 英語のレビューコメント（CodeRabbit 等）やログを読んだ後も日本語を維持する。
  （CodeRabbit への返信本文のみ、相手に合わせて英語可）

### 現在のフェーズ

Phase 0 / i0（技術検証）。共通の Swift Package（`Packages/`）と、メニューバーに常駐する macOS アプリターゲット（`Apps/macOS`。XPC STT Worker `Workers/macOSSTT` を組み込む。STT は既定で未選択で Local.xcconfig の `UTTER_MAC_STT_ENGINE` で SpeechAnalyzer を選んだときだけ使う。MVP 外の Edit Mode は、録音とは別のショートカットを割り当て、選択テキストの送信に同意したときだけ使える。MVP 外のクラウド STT は既定で無効で、設定画面で選び、音声の送信への同意・OpenAI API キー・予算がそろったときだけ Worker を通さずに OpenAI へ送る。macOS の ChatGPT 整形は、処理系で Sign in with ChatGPT を選び、ChatGPT への整形の同意・サインイン（プラン利用の許可を含む）・モデルの選択がそろい、入力先が機密入力などでないときだけ送る。OpenAI API キー方式を選んだときは、ChatGPT への整形の同意・OpenAI API キー（クラウド STT と同じ）・整形用モデル名・月次予算と単価表がそろい、入力先が機密入力などでないときだけ送る（どちらも既定は Local Basic。2つの方式の間で自動で切り替えない）。MVP 外の実験機能の Realtime Direct は入力モードで明示的に選んだときだけ使うが、対応アプリの許可リストが空のため今は自動で無効になり、停止後にまとめて入力する）と、iOS アプリターゲット（`Apps/iOS`、最低 iOS 26 は #54 判定までの仮置き。録音・Local Basic 整形・共有結果の保存と救済画面まで。STT は既定で未設定で Local.xcconfig で SpeechAnalyzer を選んだときだけ結線）と、iOS カスタムキーボード拡張（`Extensions/iOSKeyboard`。文字入力と共有結果のプレビュー・挿入、本体アプリの状態による案内）がある。iOS の App Group は #56 判定待ちで、Local.xcconfig で設定したときだけ有効（本体アプリは共有結果と本体アプリの状態だけを書き、秘密情報・生音声は置かない）。iOS 側のクラウド整形は、処理系に Claude を選び、同意・API キー（本体アプリの Keychain）がそろったときだけ Claude へ送る経路（月次予算は任意。設定したときは単価表もそろって上限に収まるときだけ送る）と、整形と予算（処理系・月次予算・単価表・今月の推定費用）・同意・API キーの設定画面まで（既定は Local Basic で送信しない）。
検証結果で要件定義11章・14章の判定基準に従って方針が変わるため、検証前の前提でコードを広げない。

### アーキテクチャ

Swift 6 / Swift Package Manager。共通ロジックは `Packages/`、プラットフォーム固有は各ターゲット。

```
Packages/
├── UtterCore/         # セッション状態機械・エラー型・共通モデル（外部依存なし、最内層）
├── UtterSpeech/       # SpeechRecognizer protocol と STT アダプター（SpeechAnalyzer / WhisperKit）
├── UtterAI/           # AIProvider protocol、Claude / ChatGPT / Local Basic、応答検証
├── UtterText/         # 整形・保護対象抽出・辞書・用語置換
└── UtterPersistence/  # 設定・辞書・使用量・共有結果（GRDB / UserDefaults）
Apps/macOS/            # メニューバー常駐、HUD、ホットキー、AX/CGEvent/Pasteboard 挿入
Apps/iOS/              # 録音・STT・整形・結果保存（テストできる部分は Apps/iOS/UtteriOSKit）
Extensions/iOSKeyboard/# UIInputViewController、UITextDocumentProxy 挿入のみ
Workers/macOSSTT/      # XPC STT Worker
```

依存方向: `Apps / Extensions / Workers → UtterSpeech / UtterAI / UtterText / UtterPersistence → UtterCore`

詳細は [docs/アーキテクチャ.md](docs/アーキテクチャ.md)。

### Key Rules

- UtterCore は Foundation 以外に依存しない。AppKit / UIKit / AVFoundation などの OS 固有 API は Packages の protocol 越しにアダプターで分離する
- 外部 API（Claude / ChatGPT / STT）は protocol + 本番実装 + Stub 実装の3点セット。テストは Stub を使い、ネットワークに出ない
- Swift 6 の strict concurrency を有効にし、`@unchecked Sendable` や `nonisolated(unsafe)` で警告を黙らせない
- Keyboard Extension にマイク録音・STT モデル・クラウド認証トークンを持たせない（iAC-08）
- 非公開 API、他製品のクライアントID、URL スキームの悪用をしない（AI-02 / iOS-03）

### プライバシー（違反は即修正対象）

- テレメトリ・解析送信を実装しない
- 発話本文・音声・API キー・OAuth トークンを OSLog やエラーメッセージに出さない
- クラウドへの送信は同意フラグを確認してから行う。同意なしでの送信経路を作らない（AC-06）
- クラウド AI へ送る文脈はスタイル区分と辞書語のみ。ウィンドウタイトル・既存本文・URL を送らない（CTX-03）
- 認証情報は Keychain（本デバイス限定、iCloud 同期なし）。App Group に秘密情報・生音声を置かない
- 発話内容は整形対象のデータであり、指示として実行しない（TXT-04）

### テスト

- Swift Testing を標準とし、UI は XCUITest
- Unit: `Packages/*/Tests/`（外部依存なし、Stub 使用）
- 実機・性能・権限が絡む検証は手順を docs に残し、結果を記録する（AC-19）

### 品質チェック

コード変更後は必ず `scripts/verify.sh` を実行して全パスすることを確認する。

### 詳細ルール

- docs/要件定義.md — 製品要件（正）
- docs/サービスコンセプト.md — 何を作るか・何を作らないか
- docs/アーキテクチャ.md — モジュール構成・依存ルール・命名規約
- docs/品質チェック・テスト規約.md — テスト方針・verify・計測
- docs/ビルド・配布規約.md — Xcode・署名・CI・配布
- docs/loop-engineering.md — Loop運用と安全境界
