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
- 読み戻しは、挿入前の `AXValue` と選択範囲から期待値を作り、挿入後の `AXValue` と完全一致するかを見る（`readBackMethod=range`）。選択範囲が取れない入力欄は、長さの増分と包含で判定する（`contains`。弱い判定）。値を読めない入力欄は `unavailable`（成功不明）になる。アプリの反映を待つため、一致するまで `--readback-timeout` 秒まで読み直す
- Pasteboard 経路では `org.nspasteboard.TransientType` と `org.nspasteboard.ConcealedType` を付ける（`--markers` で片方だけ・なしにもできる。INS-06 の比較用）。復元は、書き込み直後から changeCount が変わっていないときだけ行い、復元後に中身が退避した内容と一致するかを確かめる
- 挿入しない場合（スキップ）: フォーカス中の要素がない、セキュア入力欄（`AXSecureTextField`）、セキュア入力が有効、`--hold` の間に対象の要素が変わった、ターミナル系アプリへ改行を含む文字列（`--allow-multiline-in-terminal` なし）
- ダミー文字列はすべて `#` で始まる。シェルに入って万一 Enter が送られても、コメントとして扱われコマンドは実行されない
- Undo・目視確認・クリップボード管理アプリの履歴は、人が確かめて記録する（`--interactive` で試行ごとにターミナルで質問する）

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
```

- 連続試行（`--interactive` なし）では、最初の試行の前だけ `--delay` 秒待ち、以後は `--interval` 秒ごとに同じ入力欄へ挿入する。入力欄に文字列がたまっていくが、読み戻しは毎回の挿入前の値と比べる
- `--interactive` では、試行ごとに目視確認（読み戻しで確認できなかったときだけ）、⌘Z 1回で取り消せたか、クリップボード履歴（Pasteboard 経路のみ）、メモを質問する。答えた後は次の試行の前に再び `--delay` 秒待つので、その間に対象の入力欄をクリックし直す
- ターミナル系アプリを対象にするときは、このツールを別のウィンドウ（または別のターミナルアプリ）で実行し、対象のウィンドウをクリックしてから待つ

## 出力

`--out`（既定 `./results`）に追記する。`results/` は `.gitignore` 済みで、コミットしない。

- `trials.csv` / `trials.jsonl`（同じ内容）。主な列:
  - `route`, `insertionRoute`, `bundleID`, `appVersion`, `role`, `subrole`, `label`, `textPreset`
  - `response`（`InsertionResponse`）、`readBack`（`InsertionReadBack`）、`readBackMethod`
  - `result`（`classify` の結果: verified / unconfirmed / failed / skipped）
  - `outcome`: success（読み戻し一致）/ success-visual（目視で一致）/ failure / unknown（成功不明）/ skipped
  - `skipReason`, `insertMs`（挿入呼び出しの時間）, `confirmMs`（挿入開始から読み戻しの判定まで）
  - `markers`, `clipboardItems`, `clipboardTypes`, `clipboardUnreadableTypes`, `restore`（restored / restored-mismatch / skipped-changed / failed / n/a）
  - 人の記録: `visualMatch`, `undo`（once / multiple / partial / none）, `clipboardHistory`, `note`
- 入力欄の値・クリップボードの中身・挿入した文字列そのものは出力しない（プリセット名だけを残す）。値はメモリ上の比較にだけ使う

この出力を集計して、手順書の「記録テンプレート」に試行数・成功数・読み戻し・Undo・失敗理由を書き、結論を `docs/挿入互換性表.md` に書く。推測で値を書かない。

## 注意

- 挿入するのは固定のダミー文字列だけ。実在の個人情報・仕事の文章・パスワードを入れた入力欄で試さない。検証用の新しい文書・下書き・テスト用のチャンネルを使う
- `ax-value` は入力欄の値全体を書き換えるため、長い文書や書式付きの文書では書式が失われることがある。検証用の文書でだけ使う
- Pasteboard 経路は実際のクリップボードを書き換える。退避できない種別（`clipboardUnreadableTypes` > 0。遅延提供・ファイルプロミスなど）は復元できない。大事なものをコピーした状態で試さない
- 復元のための書き戻し自体も、クリップボード管理アプリには新しいコピーとして見える。履歴に「元の内容」が重複して残るかも `note` に書く
- Cmd+V は仮想キーコード 9（ANSI / JIS 配列の V）で送る。Dvorak などの配列では、配列を一時的に ABC / 日本語に切り替える
- 日本語入力（IME）がオンのとき、CGEvent 経路の文字が変換待ちになることがある。経路ごとに IME の状態を `note` に書く
- `--ax-flag` はアプリの AX の動作を変える。試行後に元の値へ戻すが、Chrome の表示が遅くなる等の影響があれば `note` に書く
- スクリーンショットや画面収録はコミットしない

## 片付け

1. システム設定 → プライバシーとセキュリティ → アクセシビリティ で、ターミナルアプリの許可を外す（検証の前から許可していた場合はそのまま）
2. `results/` と `.build/` を削除する（`trash results .build`）
3. 検証用に作った文書・下書き・入力した文字列を消す
