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
- **ロック中の読み書き**: 待ち時間を決めて「開始」→ すぐにサイドボタンでロック → 待ち時間が過ぎてから解除。待ち時間の後に全クラスの読み込みと新規書き込み（`locktest-<クラス>.json`）を試し、そのときの `isProtectedDataAvailable` と残りのバックグラウンド実行時間を記録する。バックグラウンド実行は通常 30 秒前後で打ち切られるので、待ち時間は 20 秒前後にする
- **イベント**: `scenePhase` の変化、ロック・解除の通知、キーボードから URL で起動されたこと（`via=` で候補を区別）
- **記録をコピー**: イベントと操作結果をテキストでクリップボードへ。手順書へ貼るときに使う（パス・端末識別子は含まない）

### キーボード拡張

- 上部: `hasFullAccess`、`needsInputModeSwitchKey`、App Group のコンテナ URL 取得可否、入力欄の属性、各操作の結果、手動切替の案内
- **読む**: 全保護クラスのファイルを読み、成否とエラーの種類（ドメイン・コードの連鎖）を表示
- **書く**: 拡張から `keyboard-write-test.json` を書く（フルアクセスの有無で書けるかを見る）。本体アプリの「キーボードが書いたファイルを読む」で確認できる
- **挿入**: 直前に読めた共有結果のうち最新のものを `textDocumentProxy.insertText` で挿入。読めていなければ固定のダミーを挿入し、その旨を表示
- **更新**: 入力欄の属性などを再表示（入力欄を移ったときに押す）
- **🌐**: 地球儀キー（`handleInputModeList(from:with:)`）。`needsInputModeSwitchKey` が false のときは隠れる
- **開く(ctx)**: `extensionContext.open` で `utterkeyboardprobe://` を開く。返った成否を表示
- **開く(UI)**: SwiftUI の `openURL` で同じ URL を開く。受理されたかを表示
- **⌫ / 改行**: 入力欄の後始末用

エラーの分類（EPERM = ロック中の保護クラスまたはサンドボックスの拒否、など）は表示用の推定。拡張では `isProtectedDataAvailable` を取れないため、原因の切り分けは手順書の条件（ロック中か、フルアクセスの有無）と合わせて判断する。

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
