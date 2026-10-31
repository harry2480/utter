# Phase i0 検証: キーボードから本体アプリへの導線と復帰（#53）

## 目的

iOS キーボード拡張での入力フロー確認：
- キーボード → 本体アプリへの戻り方（iOS-03）
- 元の入力欄への自動復帰（INS-06）
- UX 検証

## 実装パターン

### パターン A: URL Scheme での本体起動

```swift
// キーボード内での本体起動
URL(string: "utter://open-keyboard-settings")?.open()
```

**利点:**
- ✅ App Group 不要
- ✅ Cross-app navigation 標準

**課題:**
- ❌ 元の入力欄への自動復帰不可（アプリが異なるため）

### パターン B: App Group + Shared Container

```swift
// キーボード → 本体でハンドシェイク
let appGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.utter")
```

**利点:**
- ✅ 状態共有で復帰可能

**課題:**
- ⚠️ Full Access 要件（複雑化）

## UX 検証項目

| 項目 | 期待 | 検証方法 |
|------|------|--------|
| キーボード → 本体切り替え | スムーズ | 手動操作テスト |
| 入力欄復帰 | 自動復帰 or 手動選択 | 複数アプリ（Safari等）でテスト |
| 違和感なし | UX 評価 | ユーザーテスト |

## Phase i1 での決定

- URL Scheme のみ（シンプル）vs App Group 活用（高度）
- ユーザーフローの最適化

**推奨: URL Scheme + 手動復帰（初期版）**（検証前の想定。キーボード拡張からは URL スキームで本体アプリを開けなかったため、下の結論では手動アプリ切替を案内する）

## 検証用アプリでの確認手順と記録

上の「実装パターン」のコード片（`URL.open()` 等）は検証前の想定で、そのままでは動かない。結論は以下の実機の記録で確定する。

検証用アプリ: [Verification/iOSKeyboardProbe/README.md](../Verification/iOSKeyboardProbe/README.md)（ビルド・インストール・画面の見方・片付け）。App Group の確認（#56、[Phasei0検証-AppGroup権限.md](Phasei0検証-AppGroup権限.md)）と同じアプリを使う。

### 手順

0. キーボード拡張の設定値: `IsASCIICapable = false`、`PrimaryLanguage = ja-JP`、`RequestsOpenAccess = true`（`Verification/iOSKeyboardProbe/Keyboard/Info.plist`）。`IsASCIICapable = false` のため、URL・メールアドレス等の ASCII 向けの入力欄ではキーボードの候補から外れる可能性がある。外れた場合は記録 E の「拡張が表示されたか」に「×（IsASCIICapable=false）」と書き、必要なら Info.plist の `IsASCIICapable` を `true` にして再インストールし、同じ入力欄をもう一度試して両方を記録する
1. README に従ってインストールし、キーボード「utter Probe」を追加する（フルアクセスの有無を記録する。両方で試せるとよい）
2. 下の表の各アプリで入力欄を開き、utter Probe キーボードに切り替えて、表示された入力欄の属性を記録 E に残す（`nil` もそのまま書く）。パスワード欄・電話番号欄ではキーボードが標準に切り替わるか（iAC-06、iOS-09）も記録する
3. キーボードの「開く(ctx)」「開く(UI)」をそれぞれ押し、キーボードに表示された結果と、本体アプリが実際に開いたか（本体アプリのイベントに `via=` 付きで残る）を記録 F に残す。抜け道（非公開 API・responder chain 経由の openURL）は使わない
4. 本体アプリが開いた場合も開かなかった場合も、手動切替（ホームインジケータの左右スワイプ・App スイッチャー）で本体アプリへ移り、本体アプリで「全保護クラスで書き込む」を押す
5. 元のアプリへ戻る。左上の「◀ 元のアプリ名」、ホームインジケータのスワイプ、App スイッチャーのうち使えた方法と、同じ入力欄・カーソル位置が残っていたか、utter Probe キーボードが表示されたままか、を記録 G に残す
6. キーボードの「読む」→「挿入」で、結果が元の入力欄の元のカーソル位置に入るか（復帰後に別の入力欄・別のカーソル位置へ入っていないか）を記録 G に残す

### 記録 E: 入力欄の属性（iAC-06、PR #109 の要確認事項）

| アプリ・入力欄 | IsASCIICapable | フルアクセス | keyboardType | isSecureTextEntry | textContentType | 拡張が表示されたか |
|---|---|---|---|---|---|---|
| メモ（本文） | | | | | | |
| Safari（検索・アドレス欄） | | | | | | |
| Safari（Web フォームの通常欄） | | | | | | |
| メッセージ | | | | | | |
| メールアドレス欄（任意のアプリ） | | | | | | |
| パスワード欄（任意のアプリ） | | | | | | |
| 電話番号欄（任意のアプリ） | | | | | | |
| （その他、普段使うアプリ） | | | | | | |

### 記録 F: キーボードから本体アプリを開く導線（iOS-03）

| 候補 | フルアクセス | キーボードの表示 | 本体アプリが開いたか（イベントの via） |
|---|---|---|---|
| `extensionContext.open`（utter 本体のキーボードの「本体アプリを開く」。検証用アプリではなく utter 本体で試した） | 未記録 | 本体アプリは開かない | ×（開かなかった）。同じ URL（`utterapp://open`）を Mac から `xcrun devicectl device process launch --payload-url` で渡すと utter は起動したため、URL スキームの登録は正しく、キーボード拡張からの呼び出しだけが通らない |
| SwiftUI `openURL`（開く(UI)） | | | 未実施（下の一次情報により、試す意味が小さい） |
| 手動切替（スワイプ・App スイッチャー） | — | — | |

### 記録 G: 本体アプリから元アプリへの復帰（12.2節の未確定リスク）

| 元のアプリ | 本体アプリへの移り方 | 戻り方（◀ 戻る / スワイプ / App スイッチャー） | 同じ入力欄が残ったか | キーボードが utter Probe のままか | 復帰後に別の入力欄・カーソル位置へ入っていないか |
|---|---|---|---|---|---|
| メモ | | | | | |
| Safari | | | | | |
| メッセージ | | | | | |

記録した日付・iPhone / iOS・署名の種類: 2026-10-31（記録 F の1行目のみ）・iPhone 17 Pro / iOS 27.2・無料 Personal Team（App Group 有効、`UTTER_HOST_APP_URL_SCHEME = utterapp`）

一次情報（記録 F の裏付け）: Apple のドキュメント [`NSExtensionContext.open(_:completionHandler:)`](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)) は「拡張ポイントごとに、このメソッドに対応するかを決める。iOS では Today と iMessage の拡張ポイントが対応する」としており、キーボード拡張（`com.apple.keyboard-service`）は対象に含まれない（2026-10-31 確認）。responder chain から `UIApplication` の `openURL` を呼ぶ抜け道は非公開の挙動に頼るため使わない（iOS-03）

### 結論（14章の判定）

- キーボードから本体アプリへの導線: **不成立 → 手動アプリ切替を案内**（記録 F と上の一次情報。2026-10-31）。キーボード拡張は既定のビルドで URL スキームを持たず（`UTTER_HOST_APP_URL_SCHEME` が空）、手動で本体アプリへ切り替える手順を案内する。公開 API で本体アプリを開かずに録音を始める形は #233 で検討する
- 本体アプリから元入力欄への復帰: （実用的な手順あり / 不成立 → 手動復帰＋結果保持を標準）
