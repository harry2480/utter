# Phase 追跡

各 Phase の未実装の項目と対応する PR は、GitHub の追跡 Issue のチェックリストで管理する。この文書は入口と現状の要約だけを置く。
使えない・既定で無効な項目は [既知の制限](既知の制限.md) にまとめる。

## 追跡 Issue

| Phase | Issue | 状態 |
|---|---|---|
| Phase 1（録音・HUD・STT Worker・挿入） | #57 | 実装済み（閉じた）。既定の STT エンジンなどは Phase 0 の判定待ち |
| Phase 2（Claude / ChatGPT・辞書・文体・費用と同意） | #58 | #50 は条件つきで成立と判定（2026-10-27）。macOS の Sign in with ChatGPT は既定で無効の形で実装済みで、実機での確認と規約原文の確認が残る。OpenAI API キー方式の整形の結線（macOS・iOS）が残る |
| Phase 3（最適化・障害復旧・署名と公証・配布） | #59 | 計測に基づく最適化・実際の配布・挿入互換性表の記入が残る |
| Phase 4（Edit Mode・クラウド STT・履歴・Realtime Direct。MVP 外） | #60 | 結線は済み。Edit Mode・クラウド STT・Realtime Direct の実機での確認と、Realtime Direct の許可リスト（#41）が残る |
| Phase i1（iOS 本体アプリ） | #61 | 実装済み（閉じた） |
| Phase i2（カスタムキーボード） | #62 | 実装済み（閉じた） |
| Phase i3（互換性・低メモリ・電力・実機継続利用） | #63 | 実機での検証待ち |

## Phase 0 / i0 の検証 Issue（人の作業）

実機・権限ダイアログ・署名が要るため `loop:human` で扱う（[loop-engineering.md](loop-engineering.md)）。

| 検証 | Issue | 手順 |
|---|---|---|
| Accessibility 挿入の成功率・Undo・クリップボード復元 | #41 | [Phase0検証-Accessibility挿入成功率.md](Phase0検証-Accessibility挿入成功率.md) |
| ライセンス・依存関係・モデル配布・署名方式 | #47 | [ライセンス・依存関係.md](ライセンス・依存関係.md) |
| SpeechAnalyzer の日本語・部分認識 | #48 | [Phase0検証-SpeechAnalyzer日本語認識.md](Phase0検証-SpeechAnalyzer日本語認識.md) |
| WhisperKit のモデル選定・メモリ・安定性 | #49 | [Phase0検証-WhisperKitモデル選定.md](Phase0検証-WhisperKitモデル選定.md) |
| Sign in with ChatGPT の登録条件 | #50 | [Phase0検証-ChatGPT登録条件.md](Phase0検証-ChatGPT登録条件.md)（条件つきで成立と判定。規約原文の確認はリリース前） |
| 修飾キー単独ショートカットと Esc 捕捉の権限 | #51 | [Phase0検証-修飾キー権限.md](Phase0検証-修飾キー権限.md) |
| 速度・待機メモリ・バッテリー目標 | #52 | [Phase0検証-性能目標.md](Phase0検証-性能目標.md) |
| キーボードから本体アプリへの導線と復帰 | #53 | [Phasei0検証-キーボード導線.md](Phasei0検証-キーボード導線.md) |
| iOS の STT・メモリ・発熱と最低対応バージョン | #54 | [Phasei0検証-iOSSTT.md](Phasei0検証-iOSSTT.md) |
| App Group・個人署名・キーボードのフルアクセス | #56 | [Phasei0検証-AppGroup権限.md](Phasei0検証-AppGroup権限.md) |

## マージの決まり

- マージはマージコミットに限り、squash しない（`scripts/merge-pr.sh`）
- `scripts/verify.sh` と CI が通っていること
- 本文・音声・秘密情報をログに出さず、同意のないクラウド送信経路を足さないこと（CLAUDE.md「プライバシー」）
