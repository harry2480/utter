# Phase 0 検証: SpeechAnalyzer の日本語・部分認識（#48）

## 目的

macOS の SpeechRecognizer（Apple SpeechAnalyzer）が以下を満たすことを確認：
- 日本語音声認識の精度・速度（REC-01）
- 部分結果（途中経過）による段階的返却可否（REC-06）
- 認識中止・キャンセルの応答速度

## テスト環境

- OS: macOS 26 以上（SpeechAnalyzer は macOS 26 で追加）
- ローカライゼーション: 日本語
- 権限: Microphone access 有効

## 検証用コード

計測には [Verification/SpeechAnalyzerProbe](../Verification/SpeechAnalyzerProbe/README.md) を使う（使い捨てのコマンドラインツール）。
対応可否・アセットの状態（`status`）、暫定・確定結果と遅延（`file` / `mic`）、キャンセル応答（`--cancel-after`）、
精度評価用の結果 JSON（`batch` → `utter-eval`、[精度評価.md](精度評価.md)）、物理メモリの記録を行える。
結果は `docs/計測/` に記録する。

## 一次情報で確認できた事実（必要 OS・対応ロケール・対応デバイス・モデルの取得）

完了条件「日本語モデルの有無・対応デバイス・必要 OS を確認し、記録している」のうち、実機なしで Apple の一次情報から確かめられる部分を記録する。実測・判定は人が行う。

- 確認日：**2026-10-27**（下の出典をすべてこの日に取得した。再確認したときは、すべての出典を確認し直してこの日付を書き換える）
- 根拠にするのは Apple の公式ドキュメントと WWDC セッションだけ。第三者の記事・フォーラムの開発者の投稿は根拠にしない
- 「事実」は出典の記述の要約、「推測」は出典から utter に当てはめた解釈として分けて書く。出典で確かめられなかったものは「未確認」と書く

### 出典

| ID | 出典 | URL | 取得方法・確認できた範囲 |
|---|---|---|---|
| D1 | SpeechAnalyzer | https://developer.apple.com/documentation/speech/speechanalyzer | 本文を取得（DocC の JSON 版 `https://developer.apple.com/tutorials/data/documentation/speech/speechanalyzer.json`。D2〜D9 も同じ方法） |
| D2 | SpeechTranscriber（`isAvailable`・`supportedLocales`・`supportedLocale(equivalentTo:)`・`installedLocales` の各ページを含む） | https://developer.apple.com/documentation/speech/speechtranscriber | 本文を取得 |
| D3 | DictationTranscriber | https://developer.apple.com/documentation/speech/dictationtranscriber | 本文を取得 |
| D4 | AssetInventory（`assetInstallationRequest(supporting:)`・`reserve(locale:)`・`maximumReservedLocales`・`status(forModules:)` の各ページを含む） | https://developer.apple.com/documentation/speech/assetinventory | 本文を取得 |
| D5 | AssetInstallationRequest・`downloadAndInstall()` | https://developer.apple.com/documentation/speech/assetinstallationrequest | 本文を取得 |
| D6 | SpeechTranscriber.Preset・ReportingOption（`volatileResults`・`fastResults`） | https://developer.apple.com/documentation/speech/speechtranscriber/preset | 本文を取得 |
| D7 | SpeechTranscriber.Result・SpeechModuleResult（`isFinal`・`resultsFinalizationTime`） | https://developer.apple.com/documentation/speech/speechmoduleresult/isfinal | 本文を取得 |
| D8 | SpeechAnalyzer の `cancelAndFinishNow()`・`finalizeAndFinishThroughEndOfInput()`・`bestAvailableAudioFormat(compatibleWith:)` | https://developer.apple.com/documentation/speech/speechanalyzer/cancelandfinishnow() | 本文を取得 |
| W1 | WWDC25「Bring advanced speech-to-text to your app with SpeechAnalyzer」 | https://developer.apple.com/videos/play/wwdc2025/277/ | ページのトランスクリプトを取得。**スライドの画像（対応言語の一覧）は見られていない** |

### 1. 必要な OS

- 事実：SpeechAnalyzer・SpeechTranscriber・AssetInventory はいずれも iOS 26.0 / iPadOS 26.0 / Mac Catalyst 26.0 / macOS 26.0 / tvOS 26.0 / visionOS 26.0 から使える（各ページの対応プラットフォーム）[D1][D2][D4]
- 事実：DictationTranscriber は iOS / iPadOS / Mac Catalyst / macOS / visionOS の 26.0 から（tvOS の記載はない）[D3]
- 事実：W1 は「iOS 26 で導入」「watchOS を除くすべてのプラットフォームで使える（一定のハードウェア要件つき）」と説明している [W1]
- リポジトリの設定（`Packages/UtterSpeech/Package.swift` の `.macOS(.v26), .iOS(.v26)`）と矛盾しない

### 2. 日本語（ja-JP）が対応ロケールに入るか

- 事実：公式ドキュメントに対応ロケールの一覧はない。対応ロケールは実行時に `SpeechTranscriber.supportedLocales`（取得可能なロケールを含む）と `installedLocales`（端末にインストール済みのものだけ）で調べる API になっている [D2]
- 事実：`supportedLocales` は、端末が SpeechTranscriber に対応していなければ空の配列になる [D2]
- 事実：`supportedLocale(equivalentTo:)` は、完全に一致するロケールがなければ、言語コードが同じで地域が違う対応ロケール（インストール済みを優先）を返すことがある。その場合は利用者が対応ロケールの一覧から選び直せるようにすることが勧められている [D2]
- 事実：W1 は「SpeechTranscriber can currently transcribe these languages, with more to come」と言語の一覧をスライドで示しているが、トランスクリプトには言語名がない [W1]
- **未確認**：日本語（ja-JP）が SpeechTranscriber の対応ロケールに入るかは、一次情報の文章では確かめられなかった。W1 のスライドを人が動画で見るか、実機で確かめる（下の「実機で確かめる手順」）
- 事実：DictationTranscriber は、オンデバイスの `SFSpeechRecognizer` と同じモデル・同じ言語を使い、`SFSpeechRecognizer` がネットワーク経由でしか対応しない言語には対応しない [D3]。W1 は、DictationTranscriber は iOS 10 のオンデバイスの `SFSpeechRecognizer` と同じ言語・モデル・端末に対応すると説明している [W1]

### 3. 対応デバイス

- 事実：`SpeechTranscriber.isAvailable` は「端末のハードウェアと能力からみてこのモジュールが使えるか」を返す。使えなければ機能を無効にするか DictationTranscriber を使うよう案内されている [D2]
- 事実：W1 は SpeechTranscriber に「一定のハードウェア要件がある」と述べるが、要件の中身（チップ・メモリ等）は述べていない [W1]
- **未確認**：Apple シリコンに限るか、どの Mac / iPhone が対応するかの公式な記述は見つからなかった。`isAvailable` を対象の実機で確かめる。utter の macOS 版は要件定義で Apple シリコンを暫定対象としている（要件定義 1章）ため、まず対象の Mac で `isAvailable` が `true` になるかを記録する
- 事実：解析を同時に動かせる数は、端末のハードウェアに応じて保守的に制限され、超えると `insufficientResources` のエラーになる [D1]

### 4. モデルの取得（AssetInventory）とオフライン動作

- 事実：モデル（アセット）は Apple のサーバーからダウンロードされ、システムが管理する。一度ダウンロード・インストール・使用したアセットは、システムが保持・自動更新し、他のアプリと共有する [D4]
- 事実：手順は「モジュールを作る → ロケールを予約する（`assetInstallationRequest(supporting:)` が必要に応じて自動で予約する。`reserve(locale:)` で手動でもよい）→ `assetInstallationRequest(supporting:)` で要求を得て `downloadAndInstall()` → 完了を待つ」。プリインストール済み・他のアプリが取得済みなら、すぐに終わることがある [D4]
- 事実：状態が `installed` なら `assetInstallationRequest(supporting:)` は `nil` を返す。予約が `maximumReservedLocales` を超える場合はエラーを投げる。`maximumReservedLocales` は端末のストレージ容量によって変わりうる [D4]
- 事実：アセットはアプリの起動をまたいで残る。しばらく使われていないアセットは、システムがアプリの購読を外すことがある。不要になったら `release(reservedLocale:)` で予約を外し、システムが後で削除する [D4]
- 事実：`downloadAndInstall()` は最初の取得の試行が終わった時点で戻る。通信の問題などで取得できなかった場合、システムが後で自動的に再試行する。進み具合は `status(forModules:)` で確かめる [D5]
- 事実：`status(forModules:)` の値は `unsupported`・`supported`・`downloading`・`installed`。モジュールごとに違う場合は、この順で前のものを返す [D4]
- 事実：W1 は、文字起こしは完全にオンデバイスで行われるがモデルは取得が必要であること、モデルはシステムの領域に置かれアプリのダウンロードサイズ・ストレージ・実行時メモリを増やさない（アプリのメモリ空間の外で動く）ことを説明している [W1]
- 推測：「モデル取得後はネットワークなしで認識できる」は W1 の「entirely on device」から読めるが、機内モード等で実際に認識できるかは実機で確かめる（未確認）
- 推測：モデルがアプリのメモリ空間の外で動くため、`Verification/SpeechAnalyzerProbe` の物理メモリの記録（自プロセス）には認識モデルの分が含まれない可能性がある。性能目標（メモリ）を判定するときに考慮する

### 5. 暫定（volatile）・確定（final）の結果の出し方

- 事実：暫定結果は `SpeechTranscriber.ReportingOption.volatileResults` で有効になる。同じ音声の範囲について、認識が改善されるたびに複数回結果が届く [D6]。有効にしなければ確定結果だけが届き、前の結果を置き換えることはない [W1]
- 事実：`fastResults` は応答性を優先し、「速いが精度の低い」結果を返す（より小さい文脈の窓を使う）[D6]
- 事実：プリセットの中身は次のとおり [D6]

| プリセット | volatileResults | fastResults | alternativeTranscriptions | audioTimeRange |
|---|---|---|---|---|
| `transcription` | なし | なし | なし | なし |
| `transcriptionWithAlternatives` | なし | なし | あり | なし |
| `timeIndexedTranscriptionWithAlternatives` | なし | なし | あり | あり |
| `progressiveTranscription` | あり | あり | なし | なし |
| `timeIndexedProgressiveTranscription` | あり | あり | なし | あり |

- 事実：結果が確定か暫定かは `isFinal`。`false` の結果は暫定で、後でその範囲の結果が届くかどうかは分からない。**暫定結果が `isFinal == true` で出し直される保証はない** [D7]
- 事実：`isFinal` は `resultsFinalizationTime >= range.end` と同じ。`resultsFinalizationTime` より前の範囲の、これまでに届いた結果も確定とみなせる。また、確定によって暫定結果が変わらなかった範囲については、モジュールは新しい確定結果を出さなくてもよい [D7]
- 事実：W1 のサンプルは、確定結果が届いたら暫定のテキストを消して確定のテキストに連結し、録音の停止時に `finalizeAndFinishThroughEndOfInput()` を呼んで「暫定結果を確定させる」と説明している [W1]
- 事実：`cancelAndFinishNow()` は `async`（`throws` なし）で、保留中の処理をすべて取り消して解析を終える。入力の前でも終えられる [D8]。`finalizeAndFinishThroughEndOfInput()` は入力が終わって消費されるのを待ってから確定させて終える。入力の終わりより前に終えられたら `CancellationError` を投げる [D8]
- 事実：`bestAvailableAudioFormat(compatibleWith:)` は、追加のアセットのインストールが必要なら `nil` を返す。解析器は音声のリサンプリング・変換を暗黙には行わない [D8]

### 実機で確かめる手順（一次情報で分からなかったもの）

[Verification/SpeechAnalyzerProbe](../Verification/SpeechAnalyzerProbe/README.md) の `status` で、次をそのまま記録する（副作用なし）。

1. `SpeechTranscriber.isAvailable`（対応デバイスか）
2. `ja_JP` に対する `supportedLocale(equivalentTo:)` の結果（`nil` なら非対応。返ったロケールの識別子が `ja_JP` か、地域の違う近い値かも記録する）
3. `supportedLocales` の数と、`installedLocales` に含まれるか
4. `AssetInventory.status`（`supported` なら `install` で取得してから再度 `status`）・予約済みロケールと `maximumReservedLocales`
5. 参考として `DictationTranscriber` の対応可否
6. 取得後に通信を切って `file` を実行し、オフラインで認識できるか

| 項目 | macOS（機種・OS） | iOS（機種・OS） |
|---|---|---|
| `isAvailable` | | |
| `ja_JP` の対応（解決後のロケール） | | |
| `AssetInventory.status`（取得前 → 取得後） | | |
| オフラインでの認識 | | |

### リポジトリの実装との照合（照合ではコードを変えていない。末尾の暫定結果は #48 で対策した）

`Packages/UtterSpeech/Sources/UtterSpeech/` の `TranscriptionSession.swift`（`SpeechAnalyzerSession`）・`SpeechAnalyzerAssets.swift`・`TranscriptionEventMapper.swift`・`TranscriptionRun.swift` と、出典の記述を比べた。

- 一致：`SpeechTranscriber.isAvailable` → `supportedLocale(equivalentTo:)` → `AssetInventory.status(forModules:)` の順に確かめ、`installed` でなければ取得せずに `modelUnavailable` で終える。取得は `assetInstallationRequest(supporting:)` → `downloadAndInstall()` [D2][D4][D5]
- 一致：`status` の `supported` を「未取得」として扱う。`cancelAndFinishNow()` を `await` だけで呼ぶ（`throws` なし）[D4][D8]
- 一致：`progressiveTranscription` の設定に `audioTimeRange` を足しており、表の `timeIndexedProgressiveTranscription` と同じ組み合わせ（`volatileResults`・`fastResults`・`audioTimeRange`）になる [D6]
- 補足：`install()` は取得の前に `reserve(locale:)` を呼ぶ（失敗は無視）。D4 によれば `assetInstallationRequest(supporting:)` が必要に応じて自動で予約し、上限を超えるときはエラーを投げるため、事前の予約がなくても結果は同じと読める（推測）。食い違いではない
- **対策を入れた（#48）**：照合の時点の `TranscriptionEventMapper` は `isFinal == true` の結果だけを連結して `completed` の値にし、確定結果が来ないまま残った暫定結果は捨てていた。D7 は「暫定結果が確定として出し直される保証はない」「確定で変わらなかった範囲には新しい確定結果を出さなくてもよい」と書いており、W1 の説明（`finalizeAndFinishThroughEndOfInput()` で暫定結果が確定する）だけでは、最後の暫定結果のテキストが `completed` から抜けないとは言えない。そこで安全側に倒し、入力の終わりで認識を終えるときは、確定結果がカバーしていない最後の暫定部分を `completed` の末尾に含めるようにした（`TranscriptionEventMapper.completedText`）。カバーしているかは、確定結果の範囲の終わり（`range.end`）と暫定結果の範囲・音声の時刻の属性（`audioTimeRange`）で判断し、属性がまったくなければ最後の確定の後に届いた暫定結果を使う。暫定結果が後から確定として出し直された場合は確定だけを使う。空白だけの末尾は足さない。`confirmed` の意味（確定済みのチャンク）は変えず、キャンセル・失敗の扱いも変えていない。Realtime Direct は `completed` で全体のテキストを渡して差分だけを書き込むため、足した末尾は書き込み済みの範囲の後への追記になる。実機で末尾の欠けがないかは Probe で確かめる（`file` で、最後の暫定結果の後に確定結果が届くか・`resultsFinalizationTime` が `range.end` を超えて暫定結果が確定扱いになる場合があるかを記録する。確定結果が必ず届くと分かれば、この対策は何もしない）
- 補足：既定のプリセット（`progressiveTranscription`）は `fastResults` を含み、D6 は「速いが精度の低い」と書いている。精度の評価では `--preset transcription`（確定のみ・`fastResults` なし）とも比べる

## テスト手順

### 1. 日本語認識テスト

```
対象フレーズ:
- 「こんにちは」（標準）
- 「外国人登録」（複雑語彙）
- 「100円です」（数字）
- 「8月20日」（日付）

期待結果:
- 認識精度 ≥ 95%（標準語）
- 認識レイテンシー < 500ms（開始から最初の部分結果）
- 最終結果の確定時間 < 2秒
```

### 2. 部分結果の返却確認

```
手順:
1. 音声入力開始
2. 途中結果（intermediate result）を記録
3. 最終結果（final result）を記録
4. タイミング・精度の変化を分析

期待結果:
- isFinal フラグの正確性
- 最終結果は中間結果の履歴に沿って進化
```

### 3. キャンセル応答性

```
手順:
1. 認識開始後 1 秒で cancelAndFinishNow() を呼ぶ（検証用 CLI では `--cancel-after 1`。`--pace realtime` か `mic` のときだけ指定できる）
2. cancelAndFinishNow() が戻るまでの時間と、結果のストリームが終わるまでの時間を計測する（呼び出し後に届いた結果の数も記録する）

期待結果:
- 応答時間 < 100ms
- 中断後の余計な結果なし
```

## 検証結果の記録

### テスト日: YYYY-MM-DD

| テスト項目 | 結果 | 備考 |
|----------|------|------|
| 日本語認識（標準） | ✅/❌ | 精度 XX% |
| 複雑語彙 | ✅/❌ | 例: XX |
| 部分結果返却 | ✅/❌ | レイテンシ: XXms |
| キャンセル応答 | ✅/❌ | 時間: XXms |

### 制約事項

- 実際の機密情報を入力しない（テスト用フレーズのみ）
- 複数回テストして再現性確認

## 次フェーズ

- WhisperKit との比較（#49）
- 部分結果の利用（Phase 1 HUD 実装）
