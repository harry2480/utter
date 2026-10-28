# Phase 0 検証: 修飾キー単独ショートカットと Esc 捕捉の権限（#51）

## 目的

macOS の Accessibility API（CGEvent、EventMonitor）で以下を確認：
- 修飾キー単独（Cmd、Shift、Option、Control）のショートカット認識可否（REC-01）
- Esc キー捕捉の可否
- 権限要件（Accessibility access）

## 検証用コード

[Verification/HotkeyProbe](../Verification/HotkeyProbe/README.md)（macOS のコマンドラインツール）で、RegisterEventHotKey の登録と競合、CGEventTap / NSEvent による修飾キー単独の検出、セッション中だけの Esc 捕捉、権限の状態を確かめる。ビルド・実行手順とログの読み方は README を参照。
下記「3. 権限要件」の表は検証前の想定であり、HotkeyProbe の結果で確かめてから記録する。

## 一次情報で確認できた事実（方式ごとの権限・干渉、競合の検出）

完了条件「RegisterEventHotKey 等で可能な組み合わせと、イベントタップ・入力監視権限が必要な組み合わせを整理している」「ショートカット競合を検出する方法を確認している」のうち、実機なしで Apple の一次情報から確かめられる部分を記録する。実測・判定は人が行う。

- 確認日：**2026-10-27**（下の「出典」の表の A1〜A11・W1・S1〜S3 をすべてこの日に取得した。再確認したときは、この表の出典をすべて確認し直してこの日付を書き換える）。SDK のヘッダー（H1〜H9）は取得の方法も版の管理も違うため、下の「SDK のヘッダーで確認できた事実」に別の確認日と SDK の版を書く
- 根拠にするのは Apple の公式ドキュメント・WWDC セッション・Apple サポートの文書と、Xcode に入っている macOS SDK のヘッダー（下の「SDK のヘッダーで確認できた事実」）だけ。第三者の記事・ライブラリ・第三者が転載したヘッダーの写しは根拠にしない
- 「事実」は出典の記述の要約、「推測」は出典から utter に当てはめた解釈として分けて書く。出典で確かめられなかったものは「未確認」と書く

### 出典

| ID | 出典 | URL | 取得方法・確認できた範囲 |
|---|---|---|---|
| A1 | CGEvent.tapCreate(tap:place:options:eventsOfInterest:callback:userInfo:) | https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:) | 本文を取得（DocC の JSON 版 `https://developer.apple.com/tutorials/data/documentation/<パス>.json`。A2〜A10 も同じ方法） |
| A2 | CGEventTapOptions（`listenOnly`・`defaultTap`） | https://developer.apple.com/documentation/coregraphics/cgeventtapoptions | 本文を取得 |
| A3 | CGEventTapLocation.cgSessionEventTap | https://developer.apple.com/documentation/coregraphics/cgeventtaplocation/cgsessioneventtap | 本文を取得 |
| A4 | CGEvent.tapEnable(tap:enable:)・CGEventType.tapDisabledByTimeout / tapDisabledByUserInput | https://developer.apple.com/documentation/coregraphics/cgevent/tapenable(tap:enable:) | 本文を取得 |
| A5 | CGEventType.flagsChanged | https://developer.apple.com/documentation/coregraphics/cgeventtype/flagschanged | 本文を取得（`CGEventFlags.maskSecondaryFn` のページは出典にしていない。その定義はヘッダー [H7] で確かめた） |
| A6 | NSEvent.addGlobalMonitorForEvents(matching:handler:) | https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:) | 本文を取得 |
| A7 | NSEvent.addLocalMonitorForEvents(matching:handler:) | https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:) | 本文を取得 |
| A8 | NSEvent.ModifierFlags.function | https://developer.apple.com/documentation/appkit/nsevent/modifierflags-swift.struct/function | 本文を取得 |
| A9 | CGPreflightListenEventAccess()・CGRequestListenEventAccess()・CGPreflightPostEventAccess() | https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess() | 取得できたが、**宣言と対応 OS（macOS 10.15 以降）だけで説明文がない** |
| A10 | AXIsProcessTrusted()・AXIsProcessTrustedWithOptions(_:) | https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted | 本文を取得 |
| A11 | Carbon Event Manager Tasks（Documentation Archive） | https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/Carbon_Event_Manager/Tasks/CarbonEventsTasks.html | 本文を取得。修飾キーのマスクの表だけを使う（ホットキーの記述はない） |
| W1 | WWDC19「Advances in macOS Security」 | https://developer.apple.com/videos/play/wwdc2019/701/ | ページのトランスクリプトを取得 |
| S1 | Apple サポート「Change Privacy & Security settings on Mac」 | https://support.apple.com/guide/mac-help/mchl211c911f/26/mac | 直接の取得は接続を拒否されたため、`r.jina.ai` 経由で本文を取得 |
| S2 | Apple サポート「Keyboard settings on Mac」 | https://support.apple.com/guide/mac-help/kbdm162/mac | `r.jina.ai` 経由で本文を取得（取得時のページは macOS 27 のガイド） |
| S3 | Apple サポート「Dictate messages and documents on Mac」 | https://support.apple.com/guide/mac-help/mh40584/mac | `r.jina.ai` 経由で本文を取得（同上） |

**取得できなかった一次情報**：`RegisterEventHotKey`・`kEventHotKeyExclusive`・`eventHotKeyExistsErr`・`CopySymbolicHotKeys` の Apple のリファレンス（DocC の JSON は 404 で、Documentation Archive でも該当のページを見つけられなかった）、`IOHIDCheckAccess` / `IOHIDRequestAccess` のリファレンス（404）、`x-apple.systempreferences:` の URL の公式な説明。Carbon の API と `IOHIDCheckAccess` / `IOHIDRequestAccess` は、Xcode の macOS SDK のヘッダーのコメントで確かめた（下の「SDK のヘッダーで確認できた事実」）。2026-10-28 にも `RegisterEventHotKey` の DocC の JSON（`documentation/carbon/1458886-registereventhotkey.json`）を取得しようとしたが 404 だった。

### SDK のヘッダーで確認できた事実（#51）

Apple の Web のリファレンスで確かめられなかった点を、Xcode に入っている macOS SDK のヘッダーのコメントと宣言で確かめた。ヘッダーのコメントは古い OS の時代に書かれたまま残っているものがあり（「Preferences Accessibility panel」「AXMakeProcessTrusted」等）、**今の OS での実際の挙動を保証するものではない**。ヘッダーに書かれていないことは「実機の HotkeyProbe で確かめる」とする。

- 確認日：**2026-10-28**。Xcode 27.1（27A9275）の macOS 27.0 SDK（`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`、以下 `$SDK`）。テスト環境の macOS 26 とは版が違う
- 行番号はこの SDK のもの。SDK を更新したら読み直してこの日付と版を書き換える

#### 出典（ヘッダー）

| ID | ヘッダー（`$SDK/System/Library/Frameworks/` から） | 該当箇所 |
|---|---|---|
| H1 | `Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/CarbonEvents.h` | 「Global HotKey API」の節（15380 行〜）：`HotKeyOptions`（`kEventHotKeyNoOptions`・`kEventHotKeyExclusive`、15391〜15425 行）、`RegisterEventHotKey()`（15427〜15490 行）、`UnregisterEventHotKey()`（15493〜15521 行） |
| H2 | 同上 `CarbonEvents.h` | `kHISymbolicHotKeyCode` / `Modifiers` / `Enabled`・`CopySymbolicHotKeys()`（15525〜15601 行）、`PushSymbolicHotKeyMode()`（15605〜15671 行） |
| H3 | 同上 `CarbonEvents.h` | `kEventRawKeyModifiersChanged`・`kEventHotKeyPressed`・`kEventHotKeyReleased`（4646〜4716 行）、`kEventKeyModifierNumLockBit`・`kEventKeyModifierFnBit` / `Mask`（4719〜4748 行） |
| H4 | `Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/CarbonEventsCore.h` | `eventHotKeyExistsErr`（-9878）・`eventHotKeyInvalidErr`（-9879）のコメント（143〜157 行） |
| H5 | `Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/Events.h` | 修飾キーのビット（`cmdKey` 等、106〜131 行）、仮想キーコード（`kVK_Escape`・`kVK_RightOption`・`kVK_Function` 等、264〜300 行） |
| H6 | `CoreGraphics.framework/Versions/A/Headers/CGEvent.h` | イベントタップの説明（256〜292 行）、`CGEventTapCreate`（296 行）、`CGEventTapEnable`（320〜328 行）、`CGPreflightListenEventAccess` / `CGRequestListenEventAccess` / `CGPreflightPostEventAccess` / `CGRequestPostEventAccess`（398〜408 行） |
| H7 | `CoreGraphics.framework/Versions/A/Headers/CGEventTypes.h` | `CGEventFlags`（`kCGEventFlagMaskSecondaryFn` 等、78〜99 行）、`CGEventType`（`kCGEventFlagsChanged`・`kCGEventTapDisabledBy...`、101〜132 行）、`CGEventTapLocation` / `Placement` / `Options`（401〜420 行） |
| H8 | `IOKit.framework/Versions/A/Headers/hidsystem/IOHIDLib.h` | `IOHIDRequestType`・`IOHIDAccessType`・`IOHIDCheckAccess`・`IOHIDRequestAccess`（143〜214 行） |
| H9 | `AppKit.framework/Versions/C/Headers/NSEvent.h` | `NSEventModifierFlagFunction`（175 行）、`addGlobalMonitorForEventsMatchingMask` / `addLocalMonitorForEventsMatchingMask` の説明（542〜554 行） |

#### Carbon の `RegisterEventHotKey`（未確認の点 1）

事実（ヘッダーの記述の要約）：

- `RegisterEventHotKey` は「仮想キーコードと修飾キーにもとづくグローバルなホットキー」を登録する。同じアプリ内では同じ組み合わせを1つしか登録できないが、同じ組み合わせを複数のアプリが登録でき、その場合は複数のアプリに通知が届きうる [H1]
- 引数 `inHotKeyCode` は「監視するキーの仮想キーコード」、`inHotKeyModifiers` は「探す修飾キー」。Mac OS X 10.3 以降は修飾キーに 0 を渡してよい [H1]。キーなし（修飾キー単独）を表す値はヘッダーに定義されておらず、修飾キー単独を登録できるという記述もない
- `inHotKeyModifiers` に何のビットを渡せるかの一覧は `RegisterEventHotKey` のコメントにない。`kEventKeyModifierFnMask` は「このキーボードイベントの発生時に Fn キーが押されていた」ことを表すビット（Mac OS X だけで付く）として定義されている [H3] が、`RegisterEventHotKey` に渡せるとは書かれていない
- `rightShiftKey`・`rightOptionKey`・`rightControlKey` は「Not supported on Mac OS X」とコメントされている [H5]。Carbon の修飾キーの値では左右を区別できない
- 押下は `kEventHotKeyPressed`、解放は `kEventHotKeyReleased` として、`kEventParamDirectObject`（`typeEventHotKeyID`）に登録時の ID が入って届く [H3]
- アプリの終了時に `UnregisterEventHotKey` を呼ぶ必要はなく、システムが解除する [H1]
- 権限（入力監視・アクセシビリティ）について、`RegisterEventHotKey` のコメントは何も書いていない [H1]

排他登録と戻り値（「3. ショートカット競合の検出」の未確認の点）：

- `kEventHotKeyExclusive`（Mac OS X 10.5 以降）：ホットキーは通常は排他でなく、押されると登録者すべてに通知される。排他で登録すると、排他の登録が有効な間は、同じキーコード・修飾キーを排他でなく登録した他の登録者には通知が届かなくなる。排他の登録を無効化・削除するか、持ち主のアプリが終わると、通常どおり届くようになる。排他の登録がある間も、排他でない登録そのものは受け付けられる [H1]
- 同じ `kEventHotKeyExclusive` のコメントは「そのキーコード・修飾キーに**他のホットキーがすでに登録されている**ときに排他で登録しようとするとエラーを返す」と書く [H1]。一方、`RegisterEventHotKey` の Result と `eventHotKeyExistsErr` のコメントは「他のプロセスが**排他で**登録済みのときに排他で登録しようとすると `eventHotKeyExistsErr`」と書く [H1][H4]。他のプロセスが排他でなく登録済みのときに排他の登録が失敗するかは、ヘッダーの中で記述が食い違っており、決められない
- `eventHotKeyExistsErr`（-9878）は、**今のプロセスの中で**すでに登録済みのホットキーを登録しようとしたときにも返る。複数のプロセスで同じホットキーを登録するのはエラーではない [H4]
- `eventHotKeyInvalidErr`（-9879）は「今は使われていない」[H4]

ヘッダーから言えないこと（実機の HotkeyProbe で確かめる）：

- 権限なしで登録・受信できるか（`hotkey ctrl+option+k`、入力監視・アクセシビリティをオフにして）
- 登録した組み合わせのキー入力が最前面のアプリにも届くか（ヘッダーが書くのはホットキーの登録者どうしの通知だけ）
- Fn（`kEventKeyModifierFnMask`）を修飾キーに渡して登録・受信できるか（`hotkey fn+f5`）
- 他のプロセスが排他でなく登録した組み合わせを排他で登録したときに失敗するか（上の食い違い。HotkeyProbe を排他なし・排他ありで2つ同時に動かす）

#### Carbon の `CopySymbolicHotKeys`（未確認の点 1）

事実：

- 「キーボード」の設定に定義されたシステム全体のショートカット（スクリーンショット・アクセシビリティ・キーボード操作のキー等）の情報を、`CFDictionary` の配列で返す。アプリ固有にカスタマイズしたコマンドキーは含まない [H2]
- 各辞書のキーは `kHISymbolicHotKeyCode`（仮想キーコード、CFNumber）・`kHISymbolicHotKeyModifiers`（修飾キー、CFNumber）・`kHISymbolicHotKeyEnabled`（有効か、CFBoolean）。どの辞書が「キーボード」の設定のどの項目に当たるかを知る方法は今のところない [H2]
- 修飾キーの値がどの形式（Carbon の `cmdKey` 等か、別の形式か）かはヘッダーに書かれていない [H2]
- 項目数に比例して時間がかかり、項目は今後増えるので、不必要に呼んだり性能が重要なコードで呼んだりしない [H2]
- 戻り値は今のところ `noErr` と `memFullErr`。配列は呼び出し側が解放する [H2]
- 権限について何も書いていない [H2]
- 参考：システムのショートカットを無効にする `PushSymbolicHotKeyMode` は「補助装置のアクセスを有効にする」がオンのときだけ実際に効き、オフなら要求を積むだけでモードは変わらない [H2]（utter は使っていない）

ヘッダーから言えないこと（実機の HotkeyProbe の `system-shortcuts` で確かめる）：修飾キーの値の形式、Fn / 地球儀キーや音声入力のショートカットが一覧に出るか、権限なしで取得できるか。

#### `flagsChanged` だけを見るイベントタップの権限（未確認の点 2）

事実：

- `kCGHIDEventTap`・`kCGSessionEventTap`・`kCGAnnotatedSessionEventTap`、または特定のプロセスに置いたタップが**キーの押下・解放（key up and down）のイベント**を受け取れるのは、補助装置のアクセスが有効（「Preferences Accessibility panel, Keyboard view」）か、呼び出し元が `AXMakeProcessTrusted` 等で補助装置のアクセスを許されている場合だけ [H6]（A1 と同じ記述）
- タップの作成時にこれらのイベントの監視を許されていなければ、マスクの該当ビットが外される。その結果マスクが空になったときだけ `NULL` が返る [H6]。つまり許されないビットがあってもマスクに他のビットが残れば、タップは作成され、外されたビットのイベントは届かない
- `kCGEventFlagsChanged` は `kCGEventKeyDown`・`kCGEventKeyUp` と並ぶ「Keyboard events」の1つとして宣言されている [H7]。ただし上の制限のコメントは「key up and down」とだけ書き、`flagsChanged` が制限の対象かは書いていない [H6]
- `CGPreflightListenEventAccess` は「今のプロセスがすでにイベントを聞くアクセス（event listening access）を持っているか確かめる」、`CGRequestListenEventAccess` は「なければ要求する（ダイアログが出ることがある）」。`CGPreflightPostEventAccess` / `CGRequestPostEventAccess` は「イベントを合成するアクセス（event synthesizing access）」について同じ [H6]（A9 のリファレンスにない説明文がヘッダーにはある）。ヘッダーは「入力監視」という設定の名前を書いておらず、これらとイベントタップの作成の可否の関係も書いていない
- `IOHIDCheckAccess` / `IOHIDRequestAccess` の `kIOHIDRequestTypeListenEvent` は「IOHIDManager / IOHIDDevice の API でイベントを聞く」ための要求で、利用者が許可する必要がある。`IOHIDRequestAccess` を呼ばなければ `IOHIDManagerOpen` / `IOHIDDeviceOpen` の時点で代わりに要求される。`IOHIDCheckAccess` は許可・拒否・不明（`kIOHIDAccessTypeGranted` / `Denied` / `Unknown`）を返す [H8]。ヘッダーは CGEventTap との関係を書いていない
- `CGEventTapEnable` の説明（応答しない・利用者が無効化を求めると `kCGEventTapDisabled...` がコールバックに届き、再び有効にできる）は A4 と同じ [H6][H7]

ヘッダーから言えないこと（実機の HotkeyProbe で確かめる）：`flagsChanged` だけのマスクの listenOnly タップが、入力監視・アクセシビリティがともにオフで作成できて受け取れるか、どちらかが要るか（`modifier right-option --flags-only` を権限ごとにオン・オフして）。ヘッダーの記述は入力監視の導入（macOS 10.15, W1）より前の書き方のままで、W1 の「listenOnly は入力監視」と書き方が違う。

#### Fn キー単独とシステム側の動作（未確認の点 3）

事実：

- `kCGEventFlagMaskSecondaryFn` は `CGEventFlags` の「Special key identifiers」の1つ（`NX_SECONDARYFNMASK`、0x00800000）[H7]。`NSEventModifierFlagFunction` は「いずれかのファンクションキーが押されていると付く」[H9]
- Fn キーの仮想キーコードは `kVK_Function`（0x3F）[H5]
- イベントタップには `listenOnly`（受け取るだけ）と `default`（通す・変える・捨てる）がある [H6][H7]

ヘッダーから言えないこと：Fn 単独を押したときにシステムの「fn キーを押して」の動作（入力ソースの切り替え・絵文字・音声入力）が utter の検出と一緒に起きるか、`defaultTap` で Fn の `flagsChanged` を捨てたときにシステムの動作が止まるか。ヘッダーにはシステムの Fn の動作の記述がない。実機の HotkeyProbe の `modifier fn`（キーボード設定の「fn キーを押して」を項目ごとに変えて）で確かめる。

#### NSEvent のグローバルモニタ（参考）

- `addGlobalMonitorForEventsMatchingMask` の説明は A6 と同じで、「キー関連のイベントは、アクセシビリティが有効か、アプリがアクセシビリティで信頼されている場合だけ監視できる（AXUIElement.h の `AXIsProcessTrusted` を参照）」と書く [H9]。入力監視については書いていない

### 1. 方式ごとの「できること・要る権限・待機中の干渉」

| 方式 | できること | 要る権限 | 待機中に他アプリへ干渉するか |
|---|---|---|---|
| `RegisterEventHotKey`（Carbon） | 仮想キーコードと修飾キーの組み合わせを登録し、押下・解放を受け取る [H1][H3]。キーなしを表す値はなく、修飾キー単独を登録できるという記述もない [H1] | **未確認**（W1 もヘッダー [H1] も触れていない） | 事実：排他で登録すると、同じ組み合わせを排他でなく登録した他の登録者には通知が届かなくなる [H1]。**未確認**：キー入力そのものが最前面のアプリに届かなくなるか。HotkeyProbe の `hotkey` で確かめる |
| イベントタップ `listenOnly`（`cgSessionEventTap`） | イベントを受け取るだけで、変更・転送はできない [A2]。修飾キーの変化は `flagsChanged` として届く [A5] | 入力監視。キーの押下・解放を受け取るタップは、初回は作成に失敗して `nil` を返し、システム設定へ案内するダイアログが出る [W1] | 事実：変更・転送できない [A2]。推測：他アプリへの入力の流れは変わらない |
| イベントタップ `defaultTap`（`cgSessionEventTap`） | イベントをそのまま通す・変更する・捨てることができる [A2] | アクセシビリティ（「a modifying event tap requires authorization for accessibility features」）[W1] | 事実：`tapEnable(tap:enable:)` で無効・有効を切り替えられる [A4]。推測：有効な間は対象のイベントがすべてコールバックを通るため、待機中は無効にしておく |
| `NSEvent.addGlobalMonitorForEvents` | 他アプリへ送られるイベントの写しを非同期に受け取るだけで、変更も配送の阻止もできない。自分のアプリへのイベントは届かない。`flagsChanged`・`keyDown` を監視できる [A6] | ドキュメントは「キー関連のイベントは、アクセシビリティが有効か、アプリがアクセシビリティで信頼されている場合だけ監視できる」と書く [A6]。この記述は入力監視の導入（macOS 10.15, W1）より前からのもので、今の OS でどちらの権限で足りるかは**未確認** | 事実：配送を止められない [A6]。そのため Esc の捕捉（他アプリへ渡さない）には使えない |
| `NSEvent.addLocalMonitorForEvents` | 自分のアプリに配送される前のイベントを受け取り、`nil` を返して止められる [A7] | 不要（自分のアプリへのキー入力の傍受は承認不要と説明されている）[W1] | 自分のアプリのイベントだけで、他アプリには影響しない [A7]。グローバルショートカットには使えない |

補足（事実）：

- `cgSessionEventTap` はログインセッションに HID・リモコンのイベントが入る位置に置かれる。HID のイベントが WindowServer に入る位置（`cghidEventTap`）に置けるのは root だけ [A1][A3]
- `tapCreate` のリファレンスには「キーの押下・解放を受け取れるのは root で動いているか、補助装置のアクセスが有効な場合」という OS X 10.4 当時の記述が残っている [A1]。W1（macOS 10.15）の「listenOnly は入力監視、defaultTap はアクセシビリティ」と書き方が違うため、W1 を新しい情報として扱い、macOS 26 での実際の挙動は実機で確かめる
- タップが応答しなくなった場合や、利用者がタップの無効化を求めた場合は、コールバックに無効化のイベント（`tapDisabledByTimeout`・`tapDisabledByUserInput`）が届き、`tapEnable` で再び有効にできる [A4]
- `eventsOfInterest` のうち監視を許されないイベントのビットは外され、空になると `tapCreate` は `NULL` を返す [A1]
- 権限の確認：W1 は、承認のダイアログを出さずに状態を確かめる方法として `IOHIDCheckAccess`（`kIOHIDRequestTypeListenEvent`）、ダイアログを出す方法として `IOHIDRequestAccess` を挙げる。合成イベントの送信は `kIOHIDRequestTypePostEvent` で確かめる [W1]。`CGPreflightListenEventAccess()` などは macOS 10.15 から使えるが、リファレンスに説明文がない [A9]。`AXIsProcessTrusted()` はアクセシビリティで信頼されたクライアントかを返し、`AXIsProcessTrustedWithOptions(_:)` は `kAXTrustedCheckOptionPrompt` で、信頼されていなければ利用者に知らせる（非同期で、戻り値には影響しない）[A10]
- システム設定の説明：入力監視は「マウスやトラックパッドの入力を監視し、キーボードで入力した内容を見ることをアプリに許可する」、アクセシビリティは「スクリプトやシステムコマンドを実行して Mac を操作することをアプリに許可する」[S1]

### 2. 修飾キー単独・Fn（地球儀）キー

- 事実：`CGEventFlags.maskSecondaryFn`（`kCGEventFlagMaskSecondaryFn`、0x00800000）は `CGEventFlags` の「Special key identifiers」の1つとして定義されている [H7]。どの種類のイベントで付くかは、出典にした範囲では確かめていない（**未確認**）
- 事実：`NSEvent.ModifierFlags.function` は F キー（F1 等）と移動キー（Help・Forward Delete・Home・End・Page Up / Down・矢印キー）でも付く [A8]
- 事実：Carbon の修飾キーのマスクに `kEventKeyModifierFnMask`（Fn）がある [A11][H3]。ただし `RegisterEventHotKey` の修飾キーとして Fn を受け付けるかはヘッダーにも書かれておらず**未確認**（HotkeyProbe の `hotkey fn+f5`）
- 事実：`RegisterEventHotKey` は必ず仮想キーコードを取り、キーなしを表す値はヘッダーに定義されていない [H1]。Carbon の修飾キーの値は左右を区別しない（右側のビットは「Not supported on Mac OS X」）[H5]。推測：Fn 単独・右 Option 単独などは `RegisterEventHotKey` では登録できず、イベントタップの `flagsChanged` で判定することになる。イベントタップ（入力監視）で取れるかを HotkeyProbe の `modifier` で確かめる
- **未確認**：Fn 単独を押したときにシステムの動作も一緒に起きるか。ヘッダーにも記述がない（上の「Fn キー単独とシステム側の動作」）
- 事実：システム設定の「キーボード」に「fn キーを押して」（機種により地球儀キー）の項目があり、「入力ソースを変更」「絵文字と記号を表示」「音声入力を開始」「何もしない」を選べる [S2]
- 事実：音声入力のショートカットで「Fn キーを2回押す」を選ぶと、機種によってはキーボード設定の上記の項目が自動で「音声入力を開始（Fn を2回押す）」に変わる。音声入力のショートカットは一覧から選ぶほか、「カスタマイズ」で任意のキーを割り当てられる [S3]
- 推測：Fn 単独を utter に割り当てると、システムの「fn キーを押して」の動作（入力ソースの切り替え等）や、Fn 2回押しの音声入力と同時に起きる可能性がある。listenOnly のタップはイベントを止めないため [A2]、システムの動作も起きると見込む。実機で確かめる（**未確認**）

### 3. ショートカット競合の検出

- 事実：他のプロセスが同じ組み合わせを**排他で**登録済みのときに `kEventHotKeyExclusive` で登録すると `eventHotKeyExistsErr` が返る [H1][H4]。`eventHotKeyExistsErr` は今のプロセスの中で同じ組み合わせを二重に登録したときにも返る [H4]
- **未確認**：他のプロセスが**排他でなく**登録済みの組み合わせを排他で登録したときに失敗するか。ヘッダーの中で記述が食い違う（`kEventHotKeyExclusive` のコメントは「他のホットキーが登録済みならエラー」、Result のコメントは「他のプロセスが排他で登録済みならエラー」）[H1]。HotkeyProbe を排他なし・排他ありで2つ同時に動かして確かめる。排他どうしの競合も `hotkey --exclusive`（2つのターミナルで同時に実行）で実機の戻り値を記録する
- 事実：`CopySymbolicHotKeys` は「キーボード」の設定のシステム全体のショートカットを、キーコード・修飾キー・有効かの辞書の配列で返す。アプリ固有にカスタマイズしたコマンドキーは含まず、どの辞書がどの項目かは分からない [H2]
- **未確認**：`CopySymbolicHotKeys` の修飾キーの値の形式（ヘッダーは「keyboard modifiers」とだけ書く [H2]）と、Fn・音声入力のショートカットが一覧に出るか。HotkeyProbe の `system-shortcuts` の出力を記録する
- **未確認**：他のアプリが排他でなく登録したホットキーや、他のアプリのメニューのショートカットを列挙する公開 API は見つからなかった。推測：これらとの競合は登録の時点では検出できない
- 推測：音声入力のショートカットは任意のキーにできる [S3] ため、システムのショートカットの一覧に出ない場合は、utter の割当との競合を検出できない。Fn 2回押しなどがシステムのショートカットの一覧に出るかを `system-shortcuts` で確かめる

### リポジトリの実装との照合（コードは変えていない）

`Apps/macOS/Sources/Shortcut/` の実装が使っている方式：

| 機能 | 実装 | 方式 | 一次情報から見た必要な権限 |
|---|---|---|---|
| 通常の組み合わせ（修飾キー＋キー） | `CarbonHotKeyRegistrar` | `RegisterEventHotKey`（`kEventHotKeyExclusive`、押下・解放の両方を受け取る） | 未確認（実装のコメントは「権限なし」で、HotkeyProbe で実機確認する前提。ヘッダー [H1] は権限に触れていない） |
| 修飾キー単独（Fn・右 Option 等） | `GlobalShortcutController.registerModifierOnly`・`CGKeyEventTapFactory`・`ModifierOnlyDetector` | イベントタップ `listenOnly`（`cgSessionEventTap`・`headInsertEventTap`、`flagsChanged` ほか） | 入力監視 [W1]。実装の `KeyEventTapMode.listen.requiredPermission == .inputMonitoring` と一致 |
| セッション中の Esc 捕捉 | `GlobalShortcutController.installEscapeCapture`・`EscapeCaptureFilter` | イベントタップ `defaultTap`（`keyDown`・`keyUp`）。待機中は `tapEnable` で無効 | アクセシビリティ [W1]。実装の `KeyEventTapMode.filter.requiredPermission == .accessibility` と一致。待機中に無効にするのは A4 で可能 |
| ショートカットの記録（設定画面） | `RecordingShortcutRow`（`ShortcutRecorder`） | `NSEvent.addLocalMonitorForEvents`（`keyDown`・`flagsChanged`） | 不要 [W1][A7] |
| システムのショートカットとの競合 | `SystemShortcuts` | `CopySymbolicHotKeys` | 未確認（実装のコメントは「権限不要」。ヘッダー [H2] は権限に触れていない） |

- 修飾キー単独と Esc 捕捉は、Release ビルドでは `ShortcutCapabilities.keyCombinationsOnly` で無効（イベントタップを作らない）。Debug ビルドだけ起動引数で有効にできる（`ShortcutCoordinator.capabilities()`）
- 一致：listenOnly → 入力監視、defaultTap → アクセシビリティの対応づけと、「権限がないとタップの作成に失敗する」という `CGKeyEventTapFactory` のコメント（HotkeyProbe の想定と書かれている）は、W1 の説明と一致する
- 一致：`ShortcutRecorder` が F キー・矢印キーの押下で `NSEvent` の `.function` を外す扱いは、A8 の「F キー・移動キーにも付く」と合う
- **確かめる点**：入力監視の確認・要求に `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` を使っている。ヘッダーは「イベントを聞くアクセス（event listening access）があるか確かめる・なければ要求する」と書く [H6] が、入力監視の設定との対応は書いていない。W1 が挙げる `IOHIDCheckAccess` / `IOHIDRequestAccess` のヘッダーは IOHIDManager / IOHIDDevice の API のための要求と書く [H8]。HotkeyProbe の `permissions` で、システム設定の入力監視のオン・オフと値が一致するかを確かめる

SDK のヘッダー（H1〜H9）との照合：

- 一致：`CarbonHotKeySpec` が修飾キー単独（キーなし）と Fn を含む組み合わせを `RegisterEventHotKey` に渡さないのは、ヘッダーにキーなしの値がなく、Fn を受け付けるとも書かれていないこと [H1][H3] と合う。左右を区別する修飾キー単独（右 Option 等）をイベントタップで扱うのも、Carbon の右側のビットが「Not supported on Mac OS X」[H5] であることと合う
- 一致：`CarbonHotKeyRegistrar` が `kEventHotKeyPressed` / `kEventHotKeyReleased` を受け、`kEventParamDirectObject` の `EventHotKeyID` で自分の登録かを見分けるのは H3 と合う
- 一致：`SystemShortcuts` が辞書のキー `kHISymbolicHotKeyCode` / `Modifiers` / `Enabled` を読み、項目の ID を一覧上の位置にしている（項目名を取れない）のは H2 と合う。修飾キーの形式を Carbon・NSEvent の両方で読めるようにしているのも、ヘッダーが形式を書いていないこと [H2] と矛盾しない
- **食い違い（表示の文言）**：`HotKeyRegistrationFailure.alreadyRegistered` は `eventHotKeyExistsErr` を「同じ組み合わせが他で排他登録済み。他アプリとの競合」とし、`GlobalShortcutStatusText` は「他のアプリが同じ組み合わせを使っています」と出す。H4 では `eventHotKeyExistsErr` は**今のプロセスの中での二重登録**でも返る。utter の中で同じ組み合わせを二重に登録する経路がなければ実害はない。今の実装は、Edit Mode の登録で録音と同じ組み合わせを `sameAsRecording` として断り（`EditModeShortcut`）、録音・Edit Mode とも登録し直す前に解除している。録音のショートカットを Edit Mode と同じ組み合わせに変えた場合など、登録の順序によって二重登録が起きないかは、ヘッダーではなく utter 側のテストで確かめる（コードは変えていない）
- **確かめる点（タップの作成と権限）**：`CGKeyEventTapFactory` のコメントは「権限がないと作成に失敗する」とし、作成に失敗したとき（`nil`）だけを権限の問題として扱う。H6 では、許されないイベントのビットはマスクから外され、**マスクが空になったときだけ** `NULL` が返る。修飾キー単独の「他のキーを挟まずに離したときだけ反応」（`ModifierOnlyDetector.observedEvents` が `flagsChanged`・`keyDown`・マウス）では、`keyDown` だけが許されない場合にタップが作成され、`keyDown` が届かず「他のキーを挟んだ」ことを検出できない、という状態がヘッダーの記述上ありうる。実装は作成前に `CGPreflightListenEventAccess()` を確かめるため、その値が真のときに `keyDown` が外されることがあるかを HotkeyProbe（`modifier right-option --fire-on clean-up` を権限ごとに）で確かめる。外されることがあれば、作成後に `keyDown` が届くかを確かめる処理か、権限の確認の見直しが要る
- **食い違い（出典のないコメント）**：`SystemShortcuts` のコメントは「Fn / 地球儀キーの割り当てと、Control 2回押し等の音声入力ショートカットも一覧に出ない（HotkeyProbe の結果）」「macOS 26 の実機では Carbon 形式で返った（HotkeyProbe の結果）」と書く。後者と同じ内容（macOS 26 で Carbon 形式、Fn / 地球儀キーの項目が 0x20000）は `Verification/HotkeyProbe/Sources/HotkeyProbe/CarbonHotKey.swift` のコメントと [HotkeyProbe の README](../Verification/HotkeyProbe/README.md)「読み方」にも「開発機（macOS 26）では」として書かれている。前者（Fn / 地球儀キーと音声入力ショートカットが一覧に出ない）は README「読み方」に注意書きとして書かれているだけで、Probe のソースのコメントにはない。どちらも、この文書の「検証結果の記録」には日付・機種つきで記録されていない。ヘッダー [H2] からはどちらも言えない。実測の日付・OS・機種とともに「検証結果の記録」に書き写すか、コメントを「未確認」に直す必要がある（コードは変えていない）
- 参考：`SystemShortcuts.loadEnabledBindings` はショートカットの登録時・設定画面・初回セットアップで呼ばれる。H2 は「不必要に呼ばない・性能が重要なコードで呼ばない」と書くが、キー入力ごとに呼ぶ経路はなく、食い違いはない
- **確かめる点**：権限がないときに開くシステム設定の URL（`x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent` / `?Privacy_Accessibility`）は、公式の説明を見つけられなかった（未確認）。macOS 26 で該当の画面が開くかを実機で確かめる
- **確かめる点**：下の「3. 権限要件」の表は、以前はイベントタップによるキー監視と EventMonitor を「権限不要」としており、W1・A6 と食い違っていた（実装は権限が要る前提で書かれていた）。一次情報と未確認を分けた暫定の表に置き換えた

### 実機で確かめること（一次情報で分からなかったもの）

| 項目 | HotkeyProbe のコマンド | 一次情報の状況 |
|---|---|---|
| `RegisterEventHotKey` が権限なしで登録・受信できるか、登録した組み合わせが他アプリに届くか | `hotkey ctrl+option+k` | 未確認（ヘッダー [H1] は権限と、最前面のアプリへの配送に触れていない） |
| 排他登録の競合と戻り値 | `hotkey ctrl+option+k --exclusive`（2つ同時に）。排他なしと排他ありの組み合わせも | 排他どうしは `eventHotKeyExistsErr` とヘッダーにある [H1][H4]。排他なしが先にあるときはヘッダーの記述が食い違い未確認 [H1] |
| Fn を Carbon の修飾キーとして登録できるか | `hotkey fn+f5` | 未確認（`kEventKeyModifierFnMask` はあるが、登録に使えるとは書かれていない [H1][H3]） |
| システムのショートカットの一覧（Fn・音声入力のショートカットが出るか、修飾キーの値の形式） | `system-shortcuts` | 一覧の中身（キーコード・修飾キー・有効か）はヘッダーで確認 [H2]。形式と Fn・音声入力は未確認 |
| `flagsChanged` だけの listenOnly タップに入力監視が要るか | `modifier right-option --flags-only`（入力監視・アクセシビリティをオン・オフ） | 未確認（W1・H6 ともキーの押下・解放についてだけ述べている） |
| 他のキーを挟んだかの判定に要る `keyDown` が、タップの作成に成功しても外されていることがあるか | `modifier right-option --fire-on clean-up`（権限ごとに） | H6 は「許されないビットは外し、空のときだけ NULL」と書く。実際に外れるかは未確認 |
| NSEvent のグローバルモニタで修飾キーを取るのに要る権限（入力監視かアクセシビリティか） | `modifier right-command --backend nsevent` | A6・H9 はアクセシビリティと書くが、今の OS では未確認 |
| Fn 単独を押したときにシステムの「fn キーを押して」の動作も起きるか | `modifier fn`（キーボード設定の項目を変えて）。`--tap default` で捨てたときも | 未確認（ヘッダーに記述なし） |
| `CGPreflightListenEventAccess()` の値とシステム設定の一致、許可の変更が起動中のプロセスに反映されるか | `permissions` | ヘッダーは「event listening access」と書くだけ [H6]。未確認 |

## テスト環境

- OS: macOS 26 以降
- 権限: 入力監視・アクセシビリティの要否は検証項目（システム設定 > プライバシーとセキュリティ で、実行したターミナルアプリごとにオン/オフして確かめる）

## テスト項目

### 1. 修飾キー単独認識

```
テスト対象:
- Cmd キー単独
- Shift キー単独
- Option キー単独
- Control キー単独
- Cmd+Shift 等の組み合わせ

期待結果:
- Event はキー down/up で検出可能
- 入力監視の要否は未確認（listenOnly のタップは入力監視が要ると W1 は述べる。HotkeyProbe の `modifier` で確かめる）
- アプリの入力欄へのアクセスには Accessibility 権限が要る
```

### 2. Esc キー捕捉

```
手順:
1. Esc キー押下時のイベント検出
2. システムのデフォルト動作への影響確認
3. Cmd+Esc 等との組み合わせ

期待結果:
- 検出の方式と権限は未確認（NSEvent のグローバルモニタは配送を止められない [A6]）
- Esc の捕捉（中止 vs 継続）は defaultTap で制御する想定。実機で確かめる（未確認）
```

- Push-to-talk ではトリガー（修飾キー単独・修飾キー付きの組み合わせ）を押したまま Esc を押すため、Esc にトリガーの修飾キーが付く。REC-01 の「Esc でキャンセル」を PTT でも成り立たせるには、トリガーの修飾キーを修飾キー付き Esc の判定から除く必要がある（HotkeyProbe の `session --mode ptt` で確かめる）。本番仕様として扱いを決める

### 3. 権限要件

暫定の表（実測の前。一次情報で言えることと未確認を分けた。HotkeyProbe の結果で書き換える）：

| 機能 | 権限 | 根拠・状況 |
|------|------|------|
| `RegisterEventHotKey`（修飾キー付きの組み合わせ） | **未確認** | ヘッダーに権限の記述がない [H1]。`hotkey ctrl+option+k` で確かめる |
| イベントタップ `listenOnly`（`keyDown` / `keyUp` を含む） | 入力監視（一次情報） | W1。今の OS での挙動は `modifier` で確かめる |
| イベントタップ `listenOnly`（`flagsChanged` だけ） | **未確認** | W1・H6 ともキーの押下・解放についてだけ述べている。`modifier right-option --flags-only` で確かめる |
| イベントタップ `defaultTap`（Esc の捕捉） | アクセシビリティ（一次情報） | W1。`session` で確かめる |
| `NSEvent` のグローバルモニタ（キー関連） | **未確認**（ドキュメントはアクセシビリティと書く） | A6 は入力監視の導入より前からの記述。`modifier right-command --backend nsevent` で確かめる |
| `NSEvent` のローカルモニタ（自分のアプリへのイベント） | 不要（一次情報） | W1・A7 |
| AX Element アクセス（入力欄の取得・操作, INS-01） | アクセシビリティ | A10 |

> 以前の表（検証前の想定）は「CGEvent キー監視」「EventMonitor」を権限不要としていたが、W1・A6 と食い違うため、上の暫定の表に置き換えた。

### 4. メモリ・CPU 影響

```
計測項目:
- EventMonitor アクティブ時の CPU 使用率
- メモリ増加量
- Battery drain（1時間連続稼働）

期待結果（Phase 0 目標）:
- CPU: < 2%
- メモリ: < 5MB
- Battery: 実質的な短縮なし
```

## 実装上の注意

- Global hotkey 登録は CGEvent + EventMonitor の併用推奨（堅牢性）
- Esc キー単独は Terminal 等での用途競合に注意（ユーザー設定で変更可）
- メニューバーアプリの特性上、スクリーンセーバーアクティブ時は停止すべき

## 検証結果の記録

### テスト日: YYYY-MM-DD

macOS バージョン: / キーボード（内蔵・外付け、JIS・US）:

| テスト項目 | ターミナルアプリ | 入力監視 | アクセシビリティ | 結果 | 備考 |
|----------|------|------|------|------|------|
| Cmd 単独 | | オン/オフ | オン/オフ | ✅/❌ | |
| Shift 単独 | | オン/オフ | オン/オフ | ✅/❌ | |
| fn 単独（`modifier fn`） | | オン/オフ | オン/オフ | ✅/❌ | backend / tap |
| right-option 単独（`modifier right-option`） | | オン/オフ | オン/オフ | ✅/❌ | backend / tap |
| 通常の組み合わせ（`hotkey`） | | オン/オフ | オン/オフ | ✅/❌ | 登録結果・競合 |
| Esc: 待機中の非干渉（`session`） | | オン/オフ | オン/オフ | ✅/❌ | strategy |
| Esc: 録音中の捕捉（`session`） | | オン/オフ | オン/オフ | ✅/❌ | toggle / ptt |
| Esc: 修飾キー付き Esc を通す（`session`） | | オン/オフ | オン/オフ | ✅/❌ | Cmd+Esc 等。PTT のトリガーの修飾キーは除いて判定する |
| CPU 使用率 | | | | XX% | EventMonitor 有効時 |
| メモリ増加 | | | | XXmb | |

## 次フェーズ

- ホットキーの UI カスタマイズ（Phase 1 HUD 実装）
- 権限なし時の fallback（再度権限要求）
