---
description: 外部APIやSTTエンジンとの連携を追加する。protocol + 本番実装 + Stub実装を生成する
---

# 外部API連携追加スキル

ユーザーが「Claude API の整形を追加して」「WhisperKit の認識を実装して」のように、外部 API・STT エンジンとの連携を指示したときに適用する。

## 生成するファイル（3点セット）

1. **protocol**（該当 Package の `Sources/{Module}/{Role}.swift`）
   - 例: `AIProvider`（UtterAI）、`SpeechRecognizer`（UtterSpeech）
   - 既存の protocol があれば新規作成せず、それに準拠する実装だけを追加する
   - `Sendable` に準拠させ、エラーは種類ごとに分けた型で返す（AI-06）

2. **本番実装**（同 Package の `Sources/{Module}/{Provider}{Role}.swift`）
   - 例: `ClaudeProvider`、`ChatGPTProvider`、`WhisperKitRecognizer`
   - `URLSession` やモデルローダーはイニシャライザで注入し、テストで差し替えられるようにする
   - タイムアウト・キャンセル・リトライ方針を明示する。成功不明時に無条件で再試行しない
   - モデル名・エンドポイント・単価は設定値として受け取り、コードに固定しない（AI-05 / AI-07）

3. **Stub 実装**（同 Package の `Sources/{Module}/Stub{Role}.swift`）
   - 固定応答に加えて、遅延・タイムアウト・認証失効・予算超過・空応答を注入できるようにする
   - 呼び出し回数と受け取った入力を記録し、「同意なしで呼ばれていない」ことをテストで確認できるようにする

4. **Composition Root の更新**（各アプリの起動部）
   - 認証情報の有無・同意状態・設定に応じて本番実装と Stub / Local Basic を切り替える

## ルール

- API キー・OAuth トークンは Keychain から取得する。コード・設定ファイル・ログ・エラー文言に含めない
- クラウドへ送る文脈はスタイル区分と辞書語のみ（CTX-03）
- 発話内容は整形対象のデータとして扱い、プロンプト上でも指示として解釈させない（TXT-04）
- Sign in with ChatGPT は正式に提供される登録手段のみ使う。他製品のクライアントIDや非公開エンドポイントを使わない（AI-02）
- 依存パッケージは該当 Package の `Package.swift` に追加し、ライセンスを確認してから `Package.resolved` をコミットする
- 生成後に `scripts/verify.sh` を実行する
