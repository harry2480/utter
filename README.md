# utter

話した言葉を自然な文章に整えて、いま使っているアプリの入力欄へ挿入する macOS ネイティブの音声入力アプリ（OSS）。
共通基盤を使った iOS 個人利用版（カスタムキーボード）も開発する。

> **開発状況:** Phase 0 / i0（技術検証）。まだ利用できるアプリはありません。

- 製品要件: [docs/要件定義.md](docs/要件定義.md)
- コンセプト: [docs/サービスコンセプト.md](docs/サービスコンセプト.md)
- 挿入互換性表（macOS、アプリ別の挿入経路・Undo・既知の制限）: [docs/挿入互換性表.md](docs/挿入互換性表.md)

## 特徴（目標）

- グローバルショートカットで録音 → ローカル音声認識 → 整形 → 入力欄へ挿入
- Raw / Natural / Structured の整形モード、アプリ別の文体、ユーザー辞書
- ローカル STT 優先（SpeechAnalyzer / WhisperKit）。クラウドへの送信は明示的な同意制
- AI 整形は Claude API・Sign in with ChatGPT・Local Basic から選択。API キーは各自で設定
- テレメトリなし。本文・音声をログに残さない
- 待機中はマイク・STT を止め、Mac 全体を重くしない

## 動作環境（暫定）

- macOS 26 以降 / Apple Silicon
- iOS 版は本人所有の iPhone への Xcode 実機インストールのみ（App Store 非公開）。最低対応バージョンは Phase i0 で確定（現在のビルド設定は仮置きの iOS 26）

## 開発

### 前提

- Xcode 26 以降（Swift 6）
- shellcheck・xcodegen（`brew install shellcheck xcodegen`）

### コマンド

| コマンド | 内容 |
|---|---|
| `scripts/verify.sh` | 品質チェック（swift format lint → Swift Package build/test → アプリの署名なし xcodebuild（macOS / iOS Simulator）→ shellcheck） |
| `scripts/format.sh` | swift format で自動整形 |
| `scripts/coverage.sh` | カバレッジ計測（`coverage/*.lcov` を出力） |
| `scripts/merge-pr.sh [PR]` | PR を squash マージしてブランチ削除 |
| `scripts/loop-once.sh` / `scripts/loop.sh` | Loop Engineering の実行（[運用ガイド](docs/loop-engineering.md)） |

### ビルド

macOS アプリ（現在はメニューバーに常駐するだけのスケルトン）と iOS アプリ（現在は起動画面だけのスケルトン）は、xcodegen でプロジェクトを生成してビルドします。
手順と開発用署名（`Config/Local.xcconfig`）の設定方法は [docs/ビルド・配布規約.md](docs/ビルド・配布規約.md) の「ビルド手順」を参照してください。

## プロジェクト構成

```text
utter/
├── .claude/              # Claude Code の Skills / Commands
├── .github/workflows/    # CI（macOS ランナーで scripts/verify.sh）と Loop 用ワークフロー
├── docs/                 # 要件定義・設計規約・検証結果
├── scripts/              # verify / format / Loop
├── Config/               # アプリ共通の xcconfig（署名・識別子の既定値、Local.xcconfig の雛形）
├── Packages/             # 共通 Swift Package（UtterCore / UtterSpeech / UtterAI / UtterText / UtterPersistence）
├── Apps/                 # macOS / iOS アプリ（現在はどちらもスケルトン）
├── Extensions/           # iOS カスタムキーボード
└── Workers/              # macOS XPC STT Worker
```

設計は [docs/アーキテクチャ.md](docs/アーキテクチャ.md) を参照してください。

## AI エージェントでの開発

このリポジトリは Claude Code などの AI エージェントでの開発を前提に、`CLAUDE.md`・`AGENTS.md`・`.claude/` にルールと定型作業を置いています。

```
「REC-05（最大録音時間）を実装して」
「Claude API の AIProvider を追加して」
「このエラーを直して: [エラーメッセージ]」
```

## ライセンス

[Apache License 2.0](LICENSE)。依存ライブラリとモデル重みは追加時にライセンスの両立を確認します（STT モデルは同梱せず初回取得）。
