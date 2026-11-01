# iOSKeyboardProbe（Phase i0 検証用）

本体アプリ + カスタムキーボード拡張の最小構成で、次の2つの検証 Issue を人が実機で確かめるための使い捨てプロトタイプ。本番コードではなく、`Packages/` からは参照しない。

| Issue | 手順書 | 確かめること |
|---|---|---|
| #56 App Group・個人署名・キーボードのフルアクセス | [docs/Phasei0検証-AppGroup権限.md](../../docs/Phasei0検証-AppGroup権限.md) | 無料 Personal Team で App Group が使えるか、フルアクセス無効で拡張が共有結果を読めるか、ロック中の保護クラスによる失敗（iOS-IPC-05） |
| #53 キーボードから本体アプリへの導線と元入力欄への復帰 | [docs/Phasei0検証-キーボード導線.md](../../docs/Phasei0検証-キーボード導線.md) | 公開 API で本体アプリを開けるか（iOS-03）、元アプリへの復帰と入力欄が残るか、入力欄の属性（iAC-06） |

## 構成

```
Verification/iOSKeyboardProbe/
├── project.yml                  # xcodegen の定義（.xcodeproj は生成物でコミットしない）
├── Config/Probe.xcconfig        # 既定値（ダミーの bundle ID / App Group ID）。末尾で Local.xcconfig を読む
├── Config/Local.xcconfig.example# 実機用の上書きの雛形
├── Shared/ProbeShared.swift     # 両ターゲット共通: App Group の読み書き、保護クラス、エラーの分類
├── App/                         # 本体アプリ（SwiftUI）
└── Keyboard/                    # キーボード拡張（UIInputViewController）
```

- 拡張は UIKit / SwiftUI / Foundation のみに依存し、マイク・STT モデル・クラウド認証情報・ネットワーク送信を持たない（iAC-08）。utter の Package にも依存しない
- 本体アプリを開く操作は公開 API の2候補だけを試す（`NSExtensionContext.open(_:)` と SwiftUI の `OpenURLAction`）。responder chain をたどって `UIApplication` の `openURL` を呼ぶ等の抜け道は使わない（iOS-03）。開けない場合はその結果と手動切替の案内を表示する
- 拡張はホストアプリの入力欄の本文（`documentContextBeforeInput` 等）を読まない。表示するのは `keyboardType` / `isSecureTextEntry` / `textContentType`（取れなければ `nil`）だけ

## 必要なもの

- Xcode 26 以降、`xcodegen`（`brew install xcodegen`）
- 実機検証: 本人所有の iPhone（iOS 26 以降）と Xcode に登録した Apple Account（無料 Personal Team でまず試す）

## ビルド

リポジトリのルートで実行する。

```sh
# 1. プロジェクトを生成（project.yml を変えたら毎回）
xcodegen generate --spec Verification/iOSKeyboardProbe/project.yml

# 2. シミュレータ向けに署名なしでビルドできるか確かめる（CI と同じ条件）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Verification/iOSKeyboardProbe/UtterKeyboardProbe.xcodeproj \
  -scheme UtterKeyboardProbe -sdk iphonesimulator \
  CODE_SIGNING_ALLOWED=NO build
```

`scripts/verify.sh` には組み込んでいない（CI に xcodegen の導入が要り、既存チェックを遅くするため）。変更したら上の手順で手動ビルドする。

## 実機へのインストール

1. `cp Verification/iOSKeyboardProbe/Config/Local.xcconfig.example Verification/iOSKeyboardProbe/Config/Local.xcconfig` し、`DEVELOPMENT_TEAM`・`PROBE_BUNDLE_ID_PREFIX`・`PROBE_APP_GROUP_ID` を自分の値にする。`Local.xcconfig` はコミットしない（.gitignore 済み）
2. `xcodegen generate --spec Verification/iOSKeyboardProbe/project.yml` → `open Verification/iOSKeyboardProbe/UtterKeyboardProbe.xcodeproj`
3. スキーム `UtterKeyboardProbe`、実機を選んで Run。署名エラー（App Group の Entitlement が使えない等）が出たら、**エラー文をそのまま** #56 の手順書の記録欄に残す。これが「無料 Personal Team で App Group が使えるか」の結果になる
4. 設定 → 一般 → キーボード → キーボード → 新しいキーボードを追加 → 「utter Probe」を追加
5. 本体アプリ「utter Probe」を開き、「設定」の App Group ID が自分の値で、「コンテナ URL を取得できた」になっていることを確かめる

## 画面の見方

### 本体アプリ

- **共有結果の書き込み・読み込み**: 保護クラス（complete / completeUnlessOpen / completeUntilFirstUserAuthentication / none）ごとに別ファイル（`result-<クラス>.json`）へダミー結果を書く。書き込み後に実際に付いた保護属性も表示する
- **ロック中の読み書き**: 前提として iPhone に**パスコードを設定済み**であること（未設定だと保護クラスが効かず全クラス OK になる）。また **Xcode の Stop でデバッガを外し、ホーム画面のアイコンから起動し直してから**行う（デバッガが付いたままだとバックグラウンド実行の打ち切りが本番と違う）。待ち時間を決めて「開始」→ すぐにサイドボタンでロック → 待ち時間が過ぎてから解除。待ち時間の後に全クラスの読み込みと新規書き込み（`locktest-<クラス>.json`）を試し、そのときの `isProtectedDataAvailable` と残りのバックグラウンド実行時間を記録する。バックグラウンド実行は通常 30 秒前後で打ち切られるので、待ち時間は 5〜25 秒の範囲で選べる（既定 20 秒）
- **イベント**: `scenePhase` の変化、ロック・解除の通知、キーボードから URL で起動されたこと（`via=` で候補を区別）
- **記録をコピー**: イベントと操作結果をテキストでクリップボードへ。手順書へ貼るときに使う（パス・端末識別子は含まない）

### キーボード拡張

- 上部: `hasFullAccess`、`needsInputModeSwitchKey`、App Group のコンテナ URL 取得可否、入力欄の属性、各操作の結果、手動切替の案内
- **読む**: 全保護クラスのファイルを読み、成否とエラーの種類（ドメイン・コードの連鎖）を表示
- **書く**: 拡張から `keyboard-write-test.json` を書く（フルアクセスの有無で書けるかを見る）。本体アプリの「キーボードが書いたファイルを読む」で確認できる
- **挿入**: 直前に読めた共有結果のうち最新のものを `textDocumentProxy.insertText` で挿入。読めていなければ固定のダミーを挿入し、その旨を表示。セキュア入力欄・電話番号欄（`isSecureTextEntry == true`、`keyboardType` が `phonePad` / `namePhonePad`）では挿入せず、その旨を表示する（iAC-06）
- **更新**: 入力欄の属性などを再表示（入力欄を移ったときに押す）
- **🌐**: 地球儀キー（`handleInputModeList(from:with:)`）。`needsInputModeSwitchKey` が false のときは隠れる
- **開く(ctx)**: `extensionContext.open` で `utterkeyboardprobe://` を開く。返った成否を表示
- **開く(UI)**: SwiftUI の `openURL` で同じ URL を開く。受理されたかを表示
- **⌫ / 改行**: 入力欄の後始末用

キーボード拡張の設定値は `IsASCIICapable = false`、`PrimaryLanguage = ja-JP`、`RequestsOpenAccess = true`（`Keyboard/Info.plist`）。URL・メールアドレス等の ASCII 向けの欄で候補に出ない場合の扱いは #53 の手順書を参照。

エラーの分類（EPERM = ロック中の保護クラスまたはサンドボックスの拒否、など）は表示用の推定。拡張では `isProtectedDataAvailable` を取れないため、原因の切り分けは手順書の条件（ロック中か、フルアクセスの有無）と合わせて判断する。

## 待機セッション方式の UI テスト（#233）

つないだ iPhone の上で、キーボードの🎤から録音・認識・挿入までを自動で試す（`UITests/VoiceSessionUITests.swift`）。声は Mac のスピーカーから日本語の合成音声を流し続けて、iPhone のマイクに拾わせる。

```sh
Verification/iOSKeyboardProbe/run-ui-tests.sh testSingleCycle            # 1回だけ（準備ができているかの確認）
Verification/iOSKeyboardProbe/run-ui-tests.sh testTwentyCycles testPreviewThenInsert
```

- **前提**
  - iPhone を Mac のスピーカーの近くに置き、ロックを解除しておく
  - キーボード「utter Probe」を追加し、フルアクセスをオンにしておく
  - 入力先はメモアプリの新しいメモで、テストの最後に削除する（消せなかったときは「手で消す」と出る）
- **無料の Personal Team の上限**：1台に入れられる自作アプリは3つまで。UI テストの実行役のアプリ（`UtterKeyboardProbeUITests-Runner`）が1つ使う
- **キーボードの中と App Group は UI テストから見えない**
  - キーボードは、ボタンの位置と案内の文言を App Group の `voice-keyboard.json` に書く
  - 本体アプリを `-ProbeUITest YES` で起動すると、それと本体アプリの状態・計測の記録を、読み取り用の小さな文字として出す（`UITestReadout`）
  - テストはそれを読み、ボタンは座標でタップする
  - 座標は、メモの入力欄の下の領域の下端から、OS の地球儀の段（75pt。iPhone 17 Pro・iOS 27 で測った値）だけ上にそろえている
- **キーボードの切り替え**：「次のキーボード」を短く押すと直前のキーボードに戻るだけなので、長押しの一覧から「utter Probe」を選ぶ
- **結果**：「UTTER-RESULT」で始まる行に出る。発話の本文は出さず、文字数だけを出す

| テスト | 確かめること |
|---|---|
| `testTwentyCycles` / `testTwentyCyclesMuted` | 20回続けて使い、挿入の回数・二重の挿入・区間の時間を集計する |
| `testStandbyEndurance` / `testStandbyEnduranceMuted` | 待機を始めて5分後・30分後に入力できるか（約31分） |
| `testHostTerminatedWhileRecording` | 録音中に本体アプリを強制終了したとき、何も挿入せずに案内するか |
| `testLeaveKeyboardWhileRecording` | 録音中にホーム画面へ出たとき、録音を捨て、戻ってすぐ入力できるか |
| `testCaptureLimit` | 停止の合図が来ないまま録音の上限を超えたとき、録音を捨てて知らせるか |
| `testPreviewThenInsert` | 自動挿入をオフにしたとき、プレビュー → 「挿入」で入るか |
| `testOpenHostFromKeyboard` | キーボードの「開く(ctx)」「開く(UI)」で本体アプリが前面に出るか |
| `testMicIndicatorByMode` | 待機の方式ごとに、待機中・録音中のスクリーンショットを残す（オレンジの点を見る） |
| `testRecoverAfterLock` | 人がロックと解除を行い、その後にキーボードが反応するか（#244） |
| `testDumpRecentEvents` | 直近10分の計測の記録を出す（手で試した後の確認用） |

待機の方式は起動引数 `-ProbeStandbyMode` で選ぶ。

- `holdMicrophone`：マイクを開いたまま待つ（既定）
- `mutedMicrophone`：マイクを開いて、合図まで `AVAudioApplication.setInputMuted` でミュートする。待機中にオレンジの点が出ない
- `silentPlayback`：無音を再生して待つ。裏でマイクを開けなかった

## 表示が崩れたとき

拡張は `inputView` の幅を OS に任せ、高さだけ 300pt の制約（優先度 `defaultHigh`）を付けている（`KeyboardViewController.buildLayout()`）。`inputView` の `translatesAutoresizingMaskIntoConstraints` を `false` にすると幅が決まらず、中身の最小の幅に縮むため、設定していない。実機で高さが 0 になる等の崩れが出たら、高さの制約の値か優先度を変えて再インストールし、どちらで表示できたかを PR か手順書に残す。

## 記録先

- 手順書の「記録」節（上の表のリンク先）に、端末・iOS バージョン・署名の種類と、画面の結果・「記録をコピー」の内容を転記する。推測で埋めない
- 結論は AGENTS.md に従い `docs/検証/YYYYMMDD_{検証事項}.md` にまとめる

## プライバシー

- App Group に置くのはダミー文字列だけ。テキスト欄に実際の発話・個人情報を入れない
- 記録はアプリのメモリ上にだけ持ち、OSLog やファイルに出さない。外部への送信はしない
- 表示・コピーするエラーはドメインとコードだけで、ファイルのパス（コンテナの UUID を含む）は出さない

## 片付け

1. 本体アプリの「プローブのファイルをすべて削除」で App Group 内の `UtterKeyboardProbe/` を削除
2. 設定 → 一般 → キーボード → キーボード で「utter Probe」を削除し、本体アプリを削除
3. `Verification/iOSKeyboardProbe/UtterKeyboardProbe.xcodeproj` と `Config/Local.xcconfig` を削除（どちらもコミットされない）
4. 有料 Developer Program で試した場合、不要なら Apple Developer サイトで App ID・App Group を削除
