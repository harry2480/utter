# iOSSTTProbe（Phase i0 検証用・使い捨て）

iPhone 実機で Apple の Speech API（SpeechAnalyzer）による日本語認識の精度・遅延・メモリ・熱状態を計測するための最小アプリ。
本番コードではない。`Packages/` からは参照せず、`scripts/verify.sh` のビルド対象にも含めない（swift format lint の対象には含まれる）。

- 対象 Issue: #54「Phase i0 検証: iOS の STT・メモリ・発熱と最低対応バージョン」
- 手順書: [docs/Phasei0検証-iOSSTT.md](../../docs/Phasei0検証-iOSSTT.md)、精度の計算: [docs/精度評価.md](../../docs/精度評価.md)
- 要件: 要件定義 1章（最低対応バージョン）、12.4節、12.5節（iOS-PERF-01〜05）、14章（iOS STT・メモリ・発熱）

## できること

| 項目 | 内容 |
|---|---|
| 対応状況 | 機種・iOS、`SpeechTranscriber.isAvailable`（端末の対応）、`ja_JP` の対応ロケール、導入済みロケール、アセットの状態（`AssetInventory.status`）、ロケールの予約数 |
| アセット | `AssetInventory.assetInstallationRequest` によるダウンロード（進捗表示）、ロケールの予約解除、保持中モデルの解放（`SpeechModels.endRetention`） |
| エンジン | `SpeechTranscriber`（`.progressiveTranscription` / `.transcription`）と `DictationTranscriber`（`.progressiveShortDictation` / `.shortDictation`）。暫定結果の有無、モデル保持（`whileInUse` / `lingering` / `processLifetime`）を切り替え |
| 入力 | マイク（`AVAudioSession` `.record` + `AVAudioEngine`）、または「ファイル」から選んだ音声ファイル（複数可・繰り返し可） |
| 遅延 | モデル準備（`prepareToAnalyze`）、録音開始（ボタン→最初の音声バッファの先頭サンプル。`AVAudioTime.hostTime` から求める。参考に `engine.start()` が戻るまでも記録）、初回の暫定・確定結果、停止→最終確定、ファイルの処理時間と RTF |
| 資源 | 0.5 秒ごとの `phys_footprint`（`task_vm_info`）、プロセスのピーク（`ledger_phys_footprint_peak`）、`os_proc_available_memory`、`ProcessInfo.thermalState`、電池残量、低電力モード。実行ごとの開始前・最大・終了時・終了 5 秒後、実行開始時のアセットの状態 |
| 書き出し | `results.json`（`utter-eval` が読める評価サンプル）、`metrics.json`（計測値。発話本文なし）、`timeline.csv`（資源の推移。発話本文なし）。計測値は実行ごとに `ProbeOutput/autosave-metrics.json` へ自動保存する（jetsam などで強制終了しても、それまでに終わった実行の値が残る。強制終了された実行中の値は残らないため、その回は解析データの JetsamEvent で確認する） |

録音中は画面の自動ロックを止める。電話着信などのオーディオ割り込みの開始、またはヘッドセットの抜き差しなどの入力経路の変更（`AVAudioEngineConfigurationChange`）が起きたら録音を止め、`interrupted: true` と理由を記録する。割り込みで止まった録音の途中までのテキストは評価サンプルに入れない（既存の結果も上書きしない）。

## 必要なもの

- iOS 26 以降の iPhone（SpeechAnalyzer が iOS 26 から）。`SpeechTranscriber` は対応端末が限られるため、非対応なら `DictationTranscriber` で計測する
- Xcode 26 以降（このコードは Xcode 27.0 / iOS 27.0 SDK で、配備ターゲット iOS 26.0 としてビルドを確認した）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- 実機に入れる場合は Apple ID の開発チーム（無料 Personal Team 可。約7日で失効）
- 権限: マイク、音声認識（初回の録音・ファイル認識時に許可を求める）
- アセットのダウンロード時のみネットワーク（OS が Apple から取得する。このアプリ自身は外部へ送信しない）

## ビルドと実行

```sh
# 1. Xcode プロジェクトを生成（生成物は gitignore 済み）
xcodegen generate --spec Verification/iOSSTTProbe/project.yml

# 2. シミュレータ向けに署名なしでビルドできることを確認（任意）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Verification/iOSSTTProbe/iOSSTTProbe.xcodeproj -scheme iOSSTTProbe \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

実機に入れる場合:

1. `Config/Local.xcconfig.example` を `Config/Local.xcconfig` にコピーし、`DEVELOPMENT_TEAM` と `PRODUCT_BUNDLE_IDENTIFIER` を自分の値にする（`Local.xcconfig` は gitignore 済み。コミットしない）
2. `xcodegen generate` をやり直し、`iOSSTTProbe.xcodeproj` を Xcode で開いて iPhone を選び Run
3. 計測は Debug ビルドのまま Xcode から起動してよいが、メモリ・熱の本計測は Xcode から切り離して（ケーブルを抜いて、ホーム画面から起動して）行う。デバッガ接続中は値が変わることがある

シミュレータでは SpeechTranscriber が使えない・マイク入力が実機と違うため、計測値は記録しない。

## 計測の手順

1. 「対応状況」で `端末の対応`・`ロケール`・`アセット` を確認する。`supported（未ダウンロード）` なら「アセットをダウンロード」を押す（`installed` になるまで待つ）
2. 精度を測る場合は、評価セットを用意する
   - 正解入りの JSON（[eval/results.example.json](../../eval/results.example.json) と同じ形。`sttOutput` などは無くてよい）を「評価セット（JSON）を取り込む」で読み込む
   - 音声ファイル名（拡張子なし）を評価サンプルの `id` と同じにしておくと（例: `ja-001.m4a`）、ファイル認識の結果がそのサンプルの `sttOutput` に入る。一致しない場合は `<ファイル名>-001` のサンプルを1つ作り、繰り返しでも同じサンプルを使う
   - 取り込まずに録音した場合は `mic-001` などの新しいサンプルができる。サンプルを開いて正解・区分・用語を入力する（正解が空のサンプルは書き出さない）
3. 認識する
   - マイク: 「録音の対象」を選んで「録音を開始」→話す→「停止」。録音開始遅延と停止→確定を測る
   - ファイル: 「音声ファイルを選んで認識」。複数選択と繰り返し回数で連続負荷をかけられる。「ファイルごとに 5 秒待つ」がオンなら各ファイルの後に 5 秒待って終了 5 秒後のメモリを測る。オフにすると待たずに次へ進むため、終了 5 秒後のメモリは記録しない（次の実行中の値になるため）
   - 同じ条件をコールド（アプリ起動直後、または「保持中のモデルを解放」後）とウォーム（続けてもう一度）で分けて実行する
4. 10 分連続使用の熱・電池（iOS-PERF-04）は、マイクで 10 分録音するか、ファイルの繰り返しで 10 分以上回し、`timeline.csv` の熱状態・電池の推移を見る
5. 「書き出す」→「書き出したファイルを共有」で Mac へ AirDrop する（または「ファイル」アプリの「このiPhone内 > STT Probe > ProbeOutput」から取り出す）
6. Mac で、取り出したファイルを `eval/device/<日付>-<機種>/`（gitignore 済み）に置き、精度を集計する

   ```sh
   swift run --package-path Packages/UtterEvaluation utter-eval eval/device/<日付>-<機種>/results.json
   ```

   書き出す前に、アプリは `utter-eval` が読み込みを拒否する不備（区分・意味改変の種類が不正、正規化すると正解が空、用語が英数字の境界を含めて正解に現れない、整形結果がないのに意味改変がある）のあるサンプルを除外する。判定は UtterEvaluation の `EvaluationSample.validate` / `TermAccuracy` / `TextNormalizer` を写したもの（UtterEvaluation は macOS のみの Package でリンクできないため）。除外したサンプルは画面の評価サンプル一覧に理由が出る

## Mac から自動で実行する

`Documents/AutoInput/` に評価セット `set.json` と音声 `<サンプルの id>.wav`（任意で `autorun.json`: `{"repeat": 回数, "wait": 真偽}`）を置いて起動すると、評価セットにある id の音声を名前順に認識して書き出す。アセットが未導入ならダウンロードする。すべての実行がエラーなく終わったときだけ `ProbeOutput/auto-done.txt` を、そうでなければ `ProbeOutput/auto-failed.txt` に理由を置く。評価セットを読めない・対象の音声がないときは、入力を残したまま `auto-failed.txt` を置く（直して再実行できる）。認識を始めたら、成否にかかわらず最後に `AutoInput/` を音声ごと消すので、次の起動では自動で動かず、音声も端末に残らない。置き方と取り出し方（`xcrun devicectl device copy to / from`）は [docs/計測/2026-10-31-iPhone-SpeechAnalyzer合成音声.md](../../docs/計測/2026-10-31-iPhone-SpeechAnalyzer合成音声.md) の再現手順を参照。

## 出力の記録先

- `utter-eval` の表（発話本文を含まない）と `metrics.json` の値を、手順書の記録欄と `docs/検証/YYYYMMDD_iOSSTT.md`（AGENTS.md の技術検証の置き場所）に人が転記する。推測値を書かない
- 機種・iOS・エンジン・プリセット・モデル保持・入力（マイク/ファイル）・コールド/ウォームを必ず併記する
- `results.json`（発話本文を含む）、音声ファイルはリポジトリに置かない（`eval/audio/`、`eval/device/` と、このディレクトリの `ProbeOutput/` は gitignore 済み）

### 計測値の読み方と限界

- `phys_footprint` はこのアプリのプロセスだけの値。SpeechAnalyzer のモデル推論の一部は OS のプロセスで動くため、その分は含まれない（6章「OS管理領域は別計測」）。OS 側を含めて見るには Instruments の Activity Monitor テンプレート（全プロセス）で同時に記録する
- `footprintPeakSampledMB` は 0.5 秒間隔のサンプルの最大値で、短い山を取りこぼす。`processPeakFootprintMB` は起動以降の最大値なので、1回ごとのピークを見たい場合はアプリを起動し直してから1回だけ実行する
- `thermalState` は 4 段階（nominal / fair / serious / critical）の OS の判定で、温度ではない。手順書の「+5°C」を測るには外部の温度計測が要る
- 電池残量は粗い（OS が丸めた値）。10 分程度では変化しないことがあるため、長めに回して差分を見る。充電しながら測らない
- ファイル認識は実時間より速く流し込むため、遅延の指標はマイクと比べない（RTF と処理時間を見る）。処理時間と RTF には、ファイルの読み込みと認識器の形式への変換（SpeechAnalyzer 内部）の時間も含まれる
- 録音開始遅延（`startToFirstBufferMilliseconds`）は、許可確認後にボタンの処理を始めた時刻から、最初に届いた音声バッファの先頭サンプルの時刻まで。モデル準備（コールド時はロード）を含む。`startToEngineStartedMilliseconds` は `engine.start()` が戻るまでで、実際に音声が取れ始めた時刻ではない

## 片付け

- アプリの「書き出しと認識結果をすべて削除」で、書き出したファイル（`Documents/ProbeOutput/`）、自動実行の入力（`Documents/AutoInput/`）とメモリ上の認識結果・計測値を消す（資源のサンプリングは止めず、削除後から記録し直す。サンプルに発話本文は含まれない）。または「ファイル」アプリで `STT Probe` フォルダを削除する
- アプリを削除すれば、書き出したファイルも含めてすべて消える
- Mac へ取り出した `results.json` は、集計・転記が終わったら削除する
- ダウンロードした音声アセットは OS の管理下にある。「ロケールの予約を解除」で予約を外すと、不要になったアセットを OS が後で削除する
- Mac 側: `Verification/iOSSTTProbe/iOSSTTProbe.xcodeproj`（生成物）と `Config/Local.xcconfig` は削除してよい

## プライバシー

- 発話本文は画面表示と、ユーザーが押したときの `results.json` 書き出しにだけ使う。ログ（OSLog / print）には出さない。エラー表示はエラーの種類（ドメインとコード）だけ
- テレメトリ・外部送信はない。音声は保存しない（マイク入力はメモリ上で認識器に渡すだけ）
- `metrics.json` / `timeline.csv` には発話本文・端末を一意に特定する識別子を含めない（機種の識別子 `iPhone17,1` などは含む）

## WhisperKit を足す場合（差し替え点）

このアプリは Apple の Speech API に絞っている。WhisperKit の計測を足す場合は次の点だけを差し替え、計測・書き出し（`ProbeModel` の `beginRun` / `handleResult` / `finishRun`、`ResourceMonitor`、`ProbeRecords`）はそのまま使う。

1. `Sources/SpeechAnalyzerEngine.swift` の `SpeechAnalyzerRun` と同じ形（`prepare` / `startStreaming` / `finishStreaming` / `recognize(file:)` / `cancel`、結果は `onResult(テキスト, 確定か)`）の型を追加する。`prepare` はモデルのロードにあたり、計測値 `analyzerPrepareMilliseconds` にそのまま入る
2. `EngineKind` に `whisperKit` を足し、`ProbeModel.startMicrophoneRun` / `recognize(file:)` で `SpeechAnalyzerRun` を作っている箇所を呼び分ける
3. マイク入力は `MicrophoneInput` が `AnalyzerInput` を流しているので、WhisperKit 用には 16kHz モノラル Float32 へ変換したサンプルを流す形に変える（`convert` はそのまま使える）
4. `project.yml` の `packages:` に WhisperKit を追加する（依存追加の前にライセンス確認, docs/ライセンス・依存関係.md）。モデル重みはアプリに同梱せず、初回にダウンロードする
5. WhisperKit はモデル推論がアプリのプロセス内で動くため、`phys_footprint` にモデル・GPU 領域が含まれる。SpeechAnalyzer の値と同じ条件として比べない（6章で別目標）

macOS 向けの WhisperKit 計測は #49 で別に用意している。

## 対象外

- キーボード拡張のメモリ計測（iOS-PERF-01 / 05）は別の検証で扱う
- 旧来の `SFSpeechRecognizer`（iOS 26 より前の OS で使える API）は含めない。最低対応バージョンを iOS 26 より下げるかを判断する場合は別途追加する
