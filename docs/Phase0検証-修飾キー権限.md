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

- 確認日：**2026-10-27**（下の出典をすべてこの日に取得した。再確認したときは、すべての出典を確認し直してこの日付を書き換える）
- 根拠にするのは Apple の公式ドキュメント・WWDC セッション・Apple サポートの文書だけ。第三者の記事・ライブラリ・ヘッダーの写しは根拠にしない
- 「事実」は出典の記述の要約、「推測」は出典から utter に当てはめた解釈として分けて書く。出典で確かめられなかったものは「未確認」と書く

### 出典

| ID | 出典 | URL | 取得方法・確認できた範囲 |
|---|---|---|---|
| A1 | CGEvent.tapCreate(tap:place:options:eventsOfInterest:callback:userInfo:) | https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:) | 本文を取得（DocC の JSON 版 `https://developer.apple.com/tutorials/data/documentation/<パス>.json`。A2〜A10 も同じ方法） |
| A2 | CGEventTapOptions（`listenOnly`・`defaultTap`） | https://developer.apple.com/documentation/coregraphics/cgeventtapoptions | 本文を取得 |
| A3 | CGEventTapLocation.cgSessionEventTap | https://developer.apple.com/documentation/coregraphics/cgeventtaplocation/cgsessioneventtap | 本文を取得 |
| A4 | CGEvent.tapEnable(tap:enable:)・CGEventType.tapDisabledByTimeout / tapDisabledByUserInput | https://developer.apple.com/documentation/coregraphics/cgevent/tapenable(tap:enable:) | 本文を取得 |
| A5 | CGEventType.flagsChanged・CGEventFlags.maskSecondaryFn | https://developer.apple.com/documentation/coregraphics/cgeventtype/flagschanged | 本文を取得 |
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

**取得できなかった一次情報**：`RegisterEventHotKey`・`kEventHotKeyExclusive`・`eventHotKeyExistsErr`・`CopySymbolicHotKeys` の Apple のリファレンス（DocC の JSON は 404 で、Documentation Archive でも該当のページを見つけられなかった）、`IOHIDCheckAccess` / `IOHIDRequestAccess` のリファレンス（404）、`x-apple.systempreferences:` の URL の公式な説明。Carbon の API は、人が Xcode の macOS SDK のヘッダー（`Carbon.framework` の HIToolbox の `CarbonEvents.h`・`CarbonEventsCore.h`）のコメントを読んで確かめる。

### 1. 方式ごとの「できること・要る権限・待機中の干渉」

| 方式 | できること | 要る権限 | 待機中に他アプリへ干渉するか |
|---|---|---|---|
| `RegisterEventHotKey`（Carbon） | **未確認**（公式のリファレンスを取得できなかった）。修飾キー単独（キーなし）を登録できるかの公式の記述もない | **未確認**（W1 は触れていない） | **未確認**。登録した組み合わせが他アプリに届かなくなるか、HotkeyProbe の `hotkey` で確かめる |
| イベントタップ `listenOnly`（`cgSessionEventTap`） | イベントを受け取るだけで、変更・転送はできない [A2]。修飾キーの変化は `flagsChanged` として届く [A5] | 入力監視。キーの押下・解放を受け取るタップは、初回は作成に失敗して `nil` を返し、システム設定へ案内するダイアログが出る [W1] | 事実：変更・転送できない [A2]。推測：他アプリへの入力の流れは変わらない |
| イベントタップ `defaultTap`（`cgSessionEventTap`） | イベントをそのまま通す・変更する・捨てることができる [A2] | アクセシビリティ（「a modifying event tap requires authorization for accessibility features」）[W1] | 事実：`tapEnable(tap:enable:)` で無効・有効を切り替えられる [A4]。推測：有効な間は対象のイベントがすべてコールバックを通るため、待機中は無効にしておく |
| `NSEvent.addGlobalMonitorForEvents` | 他アプリへ送られるイベントの写しを非同期に受け取るだけで、変更も配送の阻止もできない。自分のアプリへのイベントは届かない。`flagsChanged`・`keyDown` を監視できる [A6] | ドキュメントは「キー関連のイベントは、アクセシビリティが有効か、アプリがアクセシビリティで信頼されている場合だけ監視できる」と書く [A6]。この記述は入力監視の導入（macOS 10.15, W1）より前からのもので、今の OS でどちらの権限で足りるかは**未確認** | 事実：配送を止められない [A6]。そのため Esc の捕捉（他アプリへ渡さない）には使えない |
| `NSEvent.addLocalMonitorForEvents` | 自分のアプリに配送される前のイベントを受け取り、`nil` を返して止められる [A7] | 不要（自分のアプリへのキー入力の傍受は承認不要と説明されている）[W1] | 自分のアプリのイベントだけで、他アプリには影響しない [A7]。グローバルショートカットには使えない |

補足（事実）：

- `cgSessionEventTap` はログインセッションに HID・リモコンのイベントが入る位置に置かれる。HID のイベントが WindowServer に入る位置（`cghidEventTap`）に置けるのは root だけ [A1][A3]
- `tapCreate` のリファレンスには「キーの押下・解放を受け取れるのは root で動いているか、補助装置のアクセスが有効な場合」という OS X 10.4 当時の記述が残っている [A1]。W1（macOS 10.15）の「listenOnly は入力監視、defaultTap はアクセシビリティ」と書き方が違うため、W1 を新しい情報として扱い、macOS 26 での実際の挙動は実機で確かめる
- タップが応答しなくなった場合や、利用者がタップの無効化を求めた場合は、コールバックに無効化のイベント（`tapDisabledByTimeout`・`tapDisabledByUserInput`）が届き、`tapEnable` で再び有効にできる [A4][A5]
- `eventsOfInterest` のうち監視を許されないイベントのビットは外され、空になると `tapCreate` は `NULL` を返す [A1]
- 権限の確認：W1 は、承認のダイアログを出さずに状態を確かめる方法として `IOHIDCheckAccess`（`kIOHIDRequestTypeListenEvent`）、ダイアログを出す方法として `IOHIDRequestAccess` を挙げる。合成イベントの送信は `kIOHIDRequestTypePostEvent` で確かめる [W1]。`CGPreflightListenEventAccess()` などは macOS 10.15 から使えるが、リファレンスに説明文がない [A9]。`AXIsProcessTrusted()` はアクセシビリティで信頼されたクライアントかを返し、`AXIsProcessTrustedWithOptions(_:)` は `kAXTrustedCheckOptionPrompt` で、信頼されていなければ利用者に知らせる（非同期で、戻り値には影響しない）[A10]
- システム設定の説明：入力監視は「マウスやトラックパッドの入力を監視し、キーボードで入力した内容を見ることをアプリに許可する」、アクセシビリティは「スクリプトやシステムコマンドを実行して Mac を操作することをアプリに許可する」[S1]

### 2. 修飾キー単独・Fn（地球儀）キー

- 事実：`CGEventFlags.maskSecondaryFn` は、キーボード・マウス・修飾キー変化のイベントで Fn キーが押されていることを表す（主にノートの内蔵キーボードにある）[A5]
- 事実：`NSEvent.ModifierFlags.function` は F キー（F1 等）と移動キー（Help・Forward Delete・Home・End・Page Up / Down・矢印キー）でも付く [A8]
- 事実：Carbon の修飾キーのマスクに `kEventKeyModifierFnMask`（Fn）がある [A11]。ただし `RegisterEventHotKey` の修飾キーとして Fn を受け付けるかは**未確認**（HotkeyProbe の `hotkey fn+f5`）
- **未確認**：Fn 単独・修飾キー単独を `RegisterEventHotKey` で登録できないことの公式な記述は見つからなかった。修飾キー単独を `flagsChanged` で判定するのは公式の記述からの推測で、イベントタップ（入力監視）で取れるかを HotkeyProbe の `modifier` で確かめる
- 事実：システム設定の「キーボード」に「fn キーを押して」（機種により地球儀キー）の項目があり、「入力ソースを変更」「絵文字と記号を表示」「音声入力を開始」「何もしない」を選べる [S2]
- 事実：音声入力のショートカットで「Fn キーを2回押す」を選ぶと、機種によってはキーボード設定の上記の項目が自動で「音声入力を開始（Fn を2回押す）」に変わる。音声入力のショートカットは一覧から選ぶほか、「カスタマイズ」で任意のキーを割り当てられる [S3]
- 推測：Fn 単独を utter に割り当てると、システムの「fn キーを押して」の動作（入力ソースの切り替え等）や、Fn 2回押しの音声入力と同時に起きる可能性がある。listenOnly のタップはイベントを止めないため [A2]、システムの動作も起きると見込む。実機で確かめる（**未確認**）

### 3. ショートカット競合の検出

- **未確認**：`kEventHotKeyExclusive` を付けた登録が、他のプロセスの同じ組み合わせの排他登録と競合したときに失敗するか、そのときの戻り値（`eventHotKeyExistsErr` か）は、公式のリファレンスを取得できず確かめられなかった。第三者の資料には食い違う説明もあるため根拠にしない。SDK のヘッダーのコメントを読み、HotkeyProbe の `hotkey --exclusive`（2つのターミナルで同時に実行）で確かめる
- **未確認**：`CopySymbolicHotKeys` でシステムのショートカット（キーボードショートカットの設定）の一覧を取れること、その値の形式は、公式のリファレンスを取得できず確かめられなかった。HotkeyProbe の `system-shortcuts` の出力を記録する
- **未確認**：他のアプリが排他でなく登録したホットキーや、他のアプリのメニューのショートカットを列挙する公開 API は見つからなかった。推測：これらとの競合は登録の時点では検出できない
- 推測：音声入力のショートカットは任意のキーにできる [S3] ため、システムのショートカットの一覧に出ない場合は、utter の割当との競合を検出できない。Fn 2回押しなどがシステムのショートカットの一覧に出るかを `system-shortcuts` で確かめる

### リポジトリの実装との照合（コードは変えていない）

`Apps/macOS/Sources/Shortcut/` の実装が使っている方式：

| 機能 | 実装 | 方式 | 一次情報から見た必要な権限 |
|---|---|---|---|
| 通常の組み合わせ（修飾キー＋キー） | `CarbonHotKeyRegistrar` | `RegisterEventHotKey`（`kEventHotKeyExclusive`、押下・解放の両方を受け取る） | 未確認（実装のコメントは「権限なし」で、HotkeyProbe で実機確認する前提） |
| 修飾キー単独（Fn・右 Option 等） | `GlobalShortcutController.registerModifierOnly`・`CGKeyEventTapFactory`・`ModifierOnlyDetector` | イベントタップ `listenOnly`（`cgSessionEventTap`・`headInsertEventTap`、`flagsChanged` ほか） | 入力監視 [W1]。実装の `KeyEventTapMode.listen.requiredPermission == .inputMonitoring` と一致 |
| セッション中の Esc 捕捉 | `GlobalShortcutController.installEscapeCapture`・`EscapeCaptureFilter` | イベントタップ `defaultTap`（`keyDown`・`keyUp`）。待機中は `tapEnable` で無効 | アクセシビリティ [W1]。実装の `KeyEventTapMode.filter.requiredPermission == .accessibility` と一致。待機中に無効にするのは A4 で可能 |
| ショートカットの記録（設定画面） | `RecordingShortcutRow`（`ShortcutRecorder`） | `NSEvent.addLocalMonitorForEvents`（`keyDown`・`flagsChanged`） | 不要 [W1][A7] |
| システムのショートカットとの競合 | `SystemShortcuts` | `CopySymbolicHotKeys` | 未確認（実装のコメントは「権限不要」） |

- 修飾キー単独と Esc 捕捉は、Release ビルドでは `ShortcutCapabilities.keyCombinationsOnly` で無効（イベントタップを作らない）。Debug ビルドだけ起動引数で有効にできる（`ShortcutCoordinator.capabilities()`）
- 一致：listenOnly → 入力監視、defaultTap → アクセシビリティの対応づけと、「権限がないとタップの作成に失敗する」という `CGKeyEventTapFactory` のコメント（HotkeyProbe の想定と書かれている）は、W1 の説明と一致する
- 一致：`ShortcutRecorder` が F キー・矢印キーの押下で `NSEvent` の `.function` を外す扱いは、A8 の「F キー・移動キーにも付く」と合う
- **確かめる点**：入力監視の確認・要求に `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` を使っているが、リファレンスには説明文がなく [A9]、W1 が挙げるのは `IOHIDCheckAccess` / `IOHIDRequestAccess` である。名前から入力監視に当たると読める（推測）が、HotkeyProbe の `permissions` で、システム設定の入力監視のオン・オフと値が一致するかを確かめる
- **確かめる点**：権限がないときに開くシステム設定の URL（`x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent` / `?Privacy_Accessibility`）は、公式の説明を見つけられなかった（未確認）。macOS 26 で該当の画面が開くかを実機で確かめる
- **確かめる点**：下の「3. 権限要件」の表（検証前の想定）は、イベントタップによるキー監視と EventMonitor を「権限不要」としており、W1・A6 と食い違う。実装は権限が要る前提で書かれており、表の想定のほうが古い

### 実機で確かめること（一次情報で分からなかったもの）

| 項目 | HotkeyProbe のコマンド | 一次情報の状況 |
|---|---|---|
| `RegisterEventHotKey` が権限なしで登録・受信できるか、登録した組み合わせが他アプリに届くか | `hotkey ctrl+option+k` | 未確認 |
| 排他登録の競合と戻り値 | `hotkey ctrl+option+k --exclusive`（2つ同時に） | 未確認 |
| Fn を Carbon の修飾キーとして登録できるか | `hotkey fn+f5` | 未確認 |
| システムのショートカットの一覧（Fn・音声入力のショートカットが出るか） | `system-shortcuts` | 未確認 |
| `flagsChanged` だけの listenOnly タップに入力監視が要るか | `modifier right-option --flags-only`（入力監視をオン・オフ） | 未確認（W1 はキーの押下・解放について述べている） |
| NSEvent のグローバルモニタで修飾キーを取るのに要る権限（入力監視かアクセシビリティか） | `modifier right-command --backend nsevent` | A6 はアクセシビリティと書くが、今の OS では未確認 |
| Fn 単独を押したときにシステムの「fn キーを押して」の動作も起きるか | `modifier fn`（キーボード設定の項目を変えて） | 未確認 |
| `CGPreflightListenEventAccess()` の値とシステム設定の一致、許可の変更が起動中のプロセスに反映されるか | `permissions` | 未確認 |

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
- 権限なしでも基本検出可（ただしアプリの入力欄へのアクセスは要権限）
```

### 2. Esc キー捕捉

```
手順:
1. Esc キー押下時のイベント検出
2. システムのデフォルト動作への影響確認
3. Cmd+Esc 等との組み合わせ

期待結果:
- EventMonitor で検出可能
- 捕捉後の処理（中止 vs 継続）を制御可
```

- Push-to-talk ではトリガー（修飾キー単独・修飾キー付きの組み合わせ）を押したまま Esc を押すため、Esc にトリガーの修飾キーが付く。REC-01 の「Esc でキャンセル」を PTT でも成り立たせるには、トリガーの修飾キーを修飾キー付き Esc の判定から除く必要がある（HotkeyProbe の `session --mode ptt` で確かめる）。本番仕様として扱いを決める

### 3. 権限要件

| 機能 | 権限 | 説明 |
|------|------|------|
| CGEvent キー監視 | ✅ 不要 | Global hotkey 検出 |
| EventMonitor | ✅ 不要 | 標準許可 |
| AX Element アクセス | ❌ **必須** | 入力欄の取得・操作 |

**注意:** CGEvent での検出は権限不要だが、**入力欄へのアクセス（INS-01）には Accessibility 権限が必須**

> この表は検証前の想定で、「CGEvent キー監視」「EventMonitor」を権限不要としている点は、上の「一次情報で確認できた事実」の W1・A6 と食い違う（listenOnly のイベントタップは入力監視、キー関連のグローバルモニタはアクセシビリティが要ると書かれている）。表は実測の結果で書き換える。

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
