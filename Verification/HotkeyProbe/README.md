# HotkeyProbe（Phase 0 検証 #51）

修飾キー単独ショートカットと、セッション中だけの Esc 捕捉に必要な権限を、人が実機で確かめるための使い捨てのコマンドラインツール。
本番コードではない。`Packages/` からは参照しない。

- 対象 Issue: #51（REC-01, REC-02, PERM-01, 要件定義11章）
- 手順書: [docs/Phase0検証-修飾キー権限.md](../../docs/Phase0検証-修飾キー権限.md)
- ショートカットの判定は本番と同じ `UtterCore` の型（`ShortcutValidator` / `ShortcutInterpreter` / `SessionStateMachine`）を相対パス依存で使う

## 確かめること

| 問い | 使うコマンド |
|---|---|
| RegisterEventHotKey で通常の組み合わせを権限なしで登録・受信できるか | `hotkey` |
| 登録の競合（他プロセスの排他登録、システムのショートカット）を検出できるか | `hotkey --exclusive`、`system-shortcuts` |
| 修飾キー単独（Fn・右 Option 等）の押下・解放を検出できるか。必要な権限は何か | `modifier`（`--backend` / `--tap` / `--flags-only` を切り替える） |
| セッション中だけ Esc を他アプリへ渡さず、待機中は干渉しないか | `session` |

## 必要なもの

- Apple Silicon の Mac、macOS 26 以降、Xcode 26 以降
- 権限ダイアログの操作（人が行う）
- 録音・マイク・ネットワークは使わない

### 権限についての注意

- 権限は「責任のあるプロセス」に紐づく。Terminal から実行すると、入力監視・アクセシビリティは **Terminal（iTerm 等ならそのアプリ）** に対して判定・要求される。
  本番アプリは自身のバンドルに対して要求されるため、結果を記録するときは「どのターミナルアプリで実行したか」も書く。
- 権限の有無を比べるときは、システム設定 > プライバシーとセキュリティ > 入力監視 / アクセシビリティ で該当のターミナルアプリをオフにし、**ターミナルアプリを再起動してから** 実行する（許可の変更は起動中のプロセスに反映されないことがある）。
- 検証が終わったら、検証のために許可したターミナルアプリの入力監視・アクセシビリティを元に戻す。

## ビルド

`scripts/verify.sh` には組み込んでいない（実行にはイベントループと人の操作が必要で、CI では実行できないため）。手動でビルドする。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path Verification/HotkeyProbe
```

実行ファイルは `Verification/HotkeyProbe/.build/debug/HotkeyProbe`。以下は `Verification/HotkeyProbe` に移動して実行する例。

```sh
cd Verification/HotkeyProbe
.build/debug/HotkeyProbe help
```

## 使い方

`permissions` と `system-shortcuts` 以外は常駐して待つ。終了は Ctrl-C（または `--duration <秒>`）。
共通で `--log logs/<名前>.log` を付けるとファイルにも追記する（`logs/` は gitignore 済み）。

### 1. 権限の状態を見る

```sh
.build/debug/HotkeyProbe permissions
.build/debug/HotkeyProbe permissions --request-listen         # 入力監視の許可ダイアログ
.build/debug/HotkeyProbe permissions --request-accessibility  # アクセシビリティの許可ダイアログ
```

`CGPreflightListenEventAccess` / `IOHIDCheckAccess`（入力監視）、`CGPreflightPostEventAccess`、`AXIsProcessTrusted`（アクセシビリティ）、Secure Event Input の状態を表示する。

### 2. 通常の組み合わせ（RegisterEventHotKey）

```sh
.build/debug/HotkeyProbe hotkey ctrl+option+k
.build/debug/HotkeyProbe hotkey cmd+space                   # システム（Spotlight 等）と競合する例
.build/debug/HotkeyProbe hotkey ctrl+option+k --exclusive   # 2つのターミナルで同時に実行し、2つ目の登録結果を見る
.build/debug/HotkeyProbe hotkey ctrl+option+k --register-twice
.build/debug/HotkeyProbe hotkey fn+f5                       # Fn を Carbon の修飾キーとして渡したときの結果を見る
```

- 起動時に、システムのショートカット（`CopySymbolicHotKeys`）と `UtterCore.ShortcutValidator` で競合を判定して表示する
- `登録N ... → noErr / eventHotKeyExistsErr` が登録結果。登録が成功しても、システムが先に処理する組み合わせは届かないため、**実際に押して `pressed` が出るか** を確かめる
- 押下・解放は `ShortcutInterpreter`（`--mode toggle|ptt`）と `SessionStateMachine` に通し、判定結果（`interp`）と状態（`session`）を表示する

### 3. 修飾キー単独

```sh
.build/debug/HotkeyProbe modifier fn                               # CGEventTap listenOnly（既定）
.build/debug/HotkeyProbe modifier right-option --tap default       # CGEventTap defaultTap
.build/debug/HotkeyProbe modifier right-option --flags-only        # flagsChanged だけを監視
.build/debug/HotkeyProbe modifier right-command --backend nsevent  # NSEvent のグローバルモニタ
.build/debug/HotkeyProbe modifier right-option --fire-on clean-up  # 他のキーを挟まずに離したときだけ反応
```

- 対象: `fn`、`command` / `option` / `control` / `shift`（左右どちらでも）、`left-*` / `right-*`（左右を区別）
- タップを作成できないと「イベントタップを作成できません」で終了する。どの権限の組み合わせで作成でき、イベントが届くかを記録する
- `--backend nsevent` は権限がなくても登録自体は成功することがあるため、**押してログが出るか** で判定する
- 押下中に他のキーが押されたかは `押下中の他キー入力=true/false` だけを記録する（どのキーかは記録しない）。右 Option で記号を入力する等の併用と、単独押下を区別できるかの判断材料にする
- `--fire-on down`（既定）は押下で開始、`clean-up` は単独で離したときだけ開始する（Toggle のみ）
- UtterCore の `ShortcutModifiers` は左右を区別しないため、競合判定は左右をまとめた修飾キーで行う

### 4. セッション中だけ Esc を捕捉

```sh
.build/debug/HotkeyProbe session                                        # トリガー ctrl+option+k、タップをセッション中だけ有効化
.build/debug/HotkeyProbe session --esc-strategy filter                  # タップは常に有効、待機中は Esc を通す
.build/debug/HotkeyProbe session --esc-tap listen                       # listenOnly では Esc を止められないことの確認
.build/debug/HotkeyProbe session --trigger right-option --mode ptt      # 修飾キー単独をトリガーにする
```

- トリガーで録音開始（模擬）→ もう一度で停止 → 認識・整形をそれぞれ `--processing-seconds / 2` 秒で完了扱い → 挿入は即完了扱い → 待機
- 録音〜整形中（`ShortcutInterpreter.capturesEscape(in:)` が true）だけ Esc を捕捉し、セッションをキャンセルして他アプリへ渡さない。止めた Esc の keyUp とキーリピートも止める
- 修飾キー付きの Esc（Cmd+Esc、Option+Cmd+Esc 等）は常に通す
- `toggle-tap` では待機中はタップが無効なので、待機中の Esc はログに出ない。**他アプリ側で Esc が効くこと** を人が確かめる

#### 他アプリへ渡っていないかの確かめ方の例

TextEdit 等で「保存」ダイアログやフルスクリーン表示を開いて前面にし、Esc で閉じる・戻るかを見る。

1. 待機中に Esc → 他アプリで効く（干渉しない）
2. トリガーで録音開始 → Esc → 他アプリで効かず、ログに「Esc を捕捉し他アプリへ渡さない」とセッションのキャンセルが出る
3. 停止後の認識・整形中（模擬）に Esc → 2 と同じ
4. 待機に戻った後に Esc → 他アプリで効く

## ログ

各行は `時刻（ローカル、ミリ秒） up=起動からの経過ms [区分] 本文`。

- キー入力として記録するのは **対象の修飾キーと Esc だけ**。通常の文字キーのキーコード・文字は記録しない
- 修飾キーのログに出す `flags` は修飾キーの状態ビットだけで、入力した文字は含まない
- 発話・音声・権限の秘密情報は扱わない。外部送信はしない
- イベント発生から受信までの遅延は計測していない（`up=` は受信時刻）

## 記録先

結果は手順書 [docs/Phase0検証-修飾キー権限.md](../../docs/Phase0検証-修飾キー権限.md) の「検証結果の記録」に人が書く。
macOS のバージョン、実行したターミナルアプリ、キーボード（内蔵 / 外付け、JIS / US）、各権限のオン・オフ、ログの該当行を残す。
ログファイルはコミットしない。

## 片付け

```sh
rm -rf Verification/HotkeyProbe/.build Verification/HotkeyProbe/logs
```

検証のために許可したターミナルアプリの入力監視・アクセシビリティを、システム設定で元に戻す。
