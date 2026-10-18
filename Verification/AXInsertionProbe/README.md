# AXInsertionProbe（Phase 0 検証用・使い捨て）

Issue #41「Accessibility 挿入の成功率・Undo・クリップボード復元」を人が実機で計測するための、最小のコマンドラインツールである。本番コードではない。`Packages/` からは参照しない。

- 手順書: [docs/Phase0検証-Accessibility挿入成功率.md](../../docs/Phase0検証-Accessibility挿入成功率.md)
- 結論を書く表: `docs/挿入互換性表.md`（AC-20。PR #108 で追加）
- 関連要件: INS-01〜07、AC-20、要件定義 11章

## できること

指定秒数のあとに、フォーカス中の入力欄へ固定のダミー文字列を次のどれかの経路で挿入し、挿入前後の値の読み戻しで成否を判定して、試行ごとの結果を CSV / JSON Lines に追記する。

| `--route` | 内容 | 互換性表の表記（`InsertionRoute`） |
|---|---|---|
| `ax-selected` | `kAXSelectedTextAttribute` に書き込む（カーソル位置・選択範囲へ挿入） | AX（`.accessibility`） |
| `ax-value` | `kAXValueAttribute` に「選択範囲を置き換えた全体の値」を書き込み、カーソルを後ろへ移す | AX（`.accessibility`） |
| `pasteboard` | クリップボードを退避 → 文字列と一時データの印を書き込み → Cmd+V → 復元 | Pasteboard（`.pasteboard`） |
| `cgevent` | Unicode 文字列付きのキーイベントを1文字（書記素）ずつ送る | CGEvent（`.keyEvents`） |

- 判定は UtterCore の `InsertionResult.classify`（INS-05）と `ClipboardRestorePolicy`（INS-04）をそのまま使う。本番の挿入実装と同じ規則で「確認済み / 成功不明 / 失敗」を分ける
- 読み戻しは、挿入前の `AXValue` と選択範囲から期待値を作り、挿入後の `AXValue` と完全一致するかを見る（`readBackMethod=range`）。選択範囲が取れない入力欄は、長さの増分とダミー文字列の出現回数がちょうど1増えたかで判定する（`contains`。弱い判定）。値を読めない入力欄は `unavailable`（成功不明）になる。アプリの反映を待つため、一致するまで `--readback-timeout` 秒まで読み直す
- Pasteboard 経路では `org.nspasteboard.TransientType` と `org.nspasteboard.ConcealedType` を付ける（`--markers` で片方だけ・なしにもできる。INS-06 の比較用）。復元は、書き込み直後から changeCount が変わっていないときだけ行い、復元後に中身が退避した内容と一致するかを確かめる
- 挿入しない場合（スキップ）: フォーカス中の要素がない、セキュア入力欄（`AXSecureTextField`）、セキュア入力が有効、`--hold` の間に対象の要素が変わった、対象がこのツールを動かしているターミナル（`self-terminal`）、改行を含む文字列をターミナル系アプリへ送る（`multiline-in-terminal`）か cgevent 経路で送る（`multiline-keyevents`。改行が Return キーとしてチャット欄で送信になりうる）。改行の2つは `--allow-multiline` で許可できる
- ダミー文字列はすべて `#` で始まる。シェルに入って万一 Enter が送られても、`#` というコマンドとして失敗するか（zsh の既定。`interactivecomments` が無効）、コメントとして無視される（bash など）
- Undo・目視確認・誤った挿入・クリップボード管理アプリの履歴は、人が確かめて記録する（`--interactive` で試行ごとにターミナルで質問する）
- 二重挿入の防止（短時間の重複実行の抑止）はこのツールの対象外。本番の挿入実装（Phase 1）で確かめる。このツールは1回の `run` で指定回数だけ挿入し、二重に入ったかは `misinsertion` に記録する

## 必要なもの

- macOS 26 以降の Mac（実機）、Xcode（Swift 6.2 以降）
- **Accessibility の権限**: このツールを実行するターミナルアプリ（ターミナル / iTerm など）に、システム設定 → プライバシーとセキュリティ → アクセシビリティ で許可を与える。権限はツールではなく、起動したターミナルアプリに対して付く。許可した後はターミナルを再起動する
- Pasteboard / CGEvent 経路はイベント送信の権限も使う（通常はアクセシビリティの許可で通るが、`check` で必ず確かめる）
- INS-06 を確かめるときは、クリップボード管理アプリ（Maccy / Raycast / Alfred など）

## ビルドと実行

`scripts/verify.sh` には組み込んでいない（実機の権限が要るツールで、CI では実行しないため）。手動でビルドする。

```sh
cd Verification/AXInsertionProbe
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
BIN=.build/debug/ax-insertion-probe

$BIN check            # 権限の確認（--prompt で許可ダイアログを出す）
$BIN inspect          # 3秒後にフォーカス中の要素の role・書き込み可否などを表示（値の中身は表示しない）
$BIN help             # オプション一覧
```

### 計測の例

```sh
# Safari の <input> に AX（SelectedText）で20回。5秒以内に入力欄をクリックしておく
$BIN run --route ax-selected --trials 20 --label "Safari input" --text ja

# 1回ずつ、目視・Undo・クリップボード履歴を質問しながら（Undo の記録はこちら）
$BIN run --route pasteboard --trials 3 --interactive --label "Slack message"

# Chrome / Electron で AX ツリーを有効にしてから試す（試行後に元の値へ戻す）
$BIN run --route ax-selected --ax-flag AXEnhancedUserInterface --label "Chrome input"

# INS-01 の異常系: 対象を記録してから3秒待ち、その間にフォーカスを移すと挿入しない（target-changed）
$BIN run --route ax-selected --hold 3 --label "focus move"

# INS-06: 印なしと印ありで、クリップボード管理アプリの履歴を比べる
$BIN run --route pasteboard --markers none --interactive --label "markers none"
$BIN run --route pasteboard --markers both --interactive --label "markers both"

# INS-03: ターミナルへ改行入りの文字列を Pasteboard で貼り、Enter として実行されないか（bracketed paste）を見る。
# このツールは対象と別のターミナルアプリで実行する（同じアプリだと self-terminal でスキップ）
$BIN run --route pasteboard --text multiline --allow-multiline --interactive --label "Terminal multiline"
```

- 連続試行（`--interactive` なし）では、最初の試行の前だけ `--delay` 秒待ち、以後は `--interval` 秒ごとに同じ入力欄へ挿入する。入力欄に文字列がたまっていくが、読み戻しは毎回の挿入前の値と比べる
- `--interactive` では、試行ごとに目視確認（読み戻しで確認できなかったときだけ）、誤った挿入、⌘Z 1回で取り消せたか（何も入っていない試行では質問せず `n/a`。⌘Z で検証前の編集を取り消さないため）、クリップボード履歴（Pasteboard 経路のみ）、メモを質問する。答えた後は次の試行の前に再び `--delay` 秒待つので、その間に対象の入力欄をクリックし直す
- ターミナル系アプリを対象にするときは、このツールを対象とは別のターミナルアプリで実行し（例: 対象がターミナルなら iTerm から実行）、対象のウィンドウをクリックしてから待つ。起動時にフォーカス中のアプリへは挿入しない（`self-terminal`）

## 出力

`--out`（既定 `./results`）に追記する。`results/` は `.gitignore` 済みで、コミットしない。

- `trials.csv` / `trials.jsonl`（同じ内容）。主な列:
  - `route`, `insertionRoute`, `bundleID`, `appVersion`, `role`, `subrole`, `label`, `textPreset`, `axFlag`, `axFlagApplied`（`--ax-flag` の設定に成功したか）
  - `response`（`InsertionResponse`）、`readBack`（`InsertionReadBack`）、`readBackMethod`
  - `result`（`classify` の結果: verified / unconfirmed / failed / skipped）
  - `outcome`: success（読み戻し一致）/ success-visual（目視で一致）/ failure / unknown（成功不明）/ skipped
  - `skipReason`, `captureMs`（Pasteboard 経路でクリップボードの退避にかかった時間）, `insertMs`（挿入呼び出しの時間。退避を含まない）, `confirmMs`（挿入開始から読み戻しの判定まで。退避を含まない）
  - `markers`, `clipboardItems`, `clipboardTypes`, `clipboardUnreadableTypes`, `restore`（restored / restored-partial（読み出せない種別が失われた）/ restored-mismatch / skipped-changed / failed / n/a）, `restoreAfterMs`（Cmd+V の送信から復元までの時間）
  - 人の記録: `visualMatch`（yes / partial（欠け・重複・誤字）/ no（何も入っていない））, `misinsertion`（none / enter（Enter が送られた）/ other-field（別の入力欄・アプリへ入った）/ duplicate（二重に入った）。互換性表 4章の「誤った挿入」の判定に使い、1件でもあった経路は既定・代替経路にしない）, `undo`（once / multiple / partial / none / n/a）, `clipboardHistory`, `note`
- 入力欄の値・クリップボードの中身・挿入した文字列そのものは出力しない（プリセット名だけを残す）。値はメモリ上の比較にだけ使う

この出力を集計して、手順書の「記録テンプレート」に試行数・成功数・読み戻し・Undo・失敗理由を書き、結論を `docs/挿入互換性表.md` に書く。推測で値を書かない。

## 注意

- 挿入するのは固定のダミー文字列だけ。実在の個人情報・仕事の文章・パスワードを入れた入力欄で試さない。検証用の新しい文書・下書き・テスト用のチャンネルを使う
- `ax-value` は入力欄の値全体を書き換えるため、長い文書や書式付きの文書では書式が失われることがある。検証用の文書でだけ使う
- Pasteboard 経路は実際のクリップボードを書き換える。退避できない種別（`clipboardUnreadableTypes` > 0。遅延提供・ファイルプロミスなど）は復元できない。大事なものをコピーした状態で試さない
- 復元は「読み戻しの判定が出た後（一致するか `--readback-timeout` 秒の時間切れ）＋ `--restore-delay` 秒」に行う。読み戻せないアプリでは貼り付けの処理を確かめられないため、アプリが貼り付けを処理する前に復元してしまうことがある。貼り付けが欠けた・元の内容が貼られた場合は `--restore-delay` を延ばして比べ、安全な待ち時間を `note` と手順書の記録に残す
- 復元のための書き戻し自体も、クリップボード管理アプリには新しいコピーとして見える。履歴に「元の内容」が重複して残るかも `note` に書く
- Cmd+V は仮想キーコード 9（ANSI / JIS 配列の V）で送る。Dvorak などの配列では、配列を一時的に ABC / 日本語に切り替える
- 日本語入力（IME）がオンのとき、CGEvent 経路の文字が変換待ちになることがある。経路ごとに IME の状態を `note` に書く
- `--ax-flag` はアプリの AX の動作を変える。試行後に元の値へ戻すが、Chrome の表示が遅くなる等の影響があれば `note` に書く
- `skipReason=secure-input` が続く場合は、どこかのアプリがセキュア入力を有効にしている（ターミナルの「セキュアキーボード入力」、パスワード欄へのフォーカスなど）。それを外してから試す
- 要実機確認: 復元後に、ほかのアプリ由来の `dyn.*` 種別などが読み出し直しで変わり、実際には戻っているのに `restored-mismatch` になることがある。`restored-mismatch` が出たら、元の内容を貼り付けて目視で確かめ `note` に書く
- 要実機確認: Electron 系アプリ（Slack など）では、フォーカス中の要素を取り直すたびに別の `AXUIElement` が返り、同じ入力欄でも `--hold` が `target-changed` になる可能性がある。その場合は `--hold` の結果を INS-01 の判定に使わず、`note` に書く
- スクリーンショットや画面収録はコミットしない

## 片付け

1. システム設定 → プライバシーとセキュリティ → アクセシビリティ で、ターミナルアプリの許可を外す（検証の前から許可していた場合はそのまま）
2. `results/` と `.build/` を削除する（`trash results .build`）
3. 検証用に作った文書・下書き・入力した文字列を消す
