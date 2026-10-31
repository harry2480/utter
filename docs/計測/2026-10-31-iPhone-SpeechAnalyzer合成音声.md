# iPhone での SpeechAnalyzer の精度・メモリ・熱（合成音声、2026-10-31）

Phase i0 検証 [#54](https://github.com/harry2480/utter/issues/54) の「対応 Speech API の iOS での日本語精度・負荷を少数サンプルで記録」と「本体アプリのピークメモリ・発熱」の一部。
[macOS での合成音声の比較](2026-10-31-合成音声-STT比較.md) と同じ40件の音声を、[iOSSTTProbe](../../Verification/iOSSTTProbe/README.md) で iPhone 上で認識した。

**合成音声の結果は、人の声での精度の代わりにはならない。** 熱は、実際の使い方よりはるかに重い負荷（下の「連続認識」）での値。

## 条件

- 実行日：2026-10-31
- 機種：iPhone 17 Pro（`iPhone18,1`、物理メモリ 約11.4GB）・iOS 27.2
- アプリ：iOSSTTProbe の Release ビルド（デバッガなし）。Mac からケーブルでつないだまま（**充電中**。電池 55% → 65%）、画面は点けたまま
- エンジン：`SpeechTranscriber`（`progressive`、暫定結果あり、モデル保持 `whileInUse`）、ロケール `ja_JP`。日本語のアセットは計測前から導入済み（`installed`）
- 入力：音声ファイル（`say -v Kyoko` の 16kHz・モノラル・16bit）。ファイル認識は実時間より速く流し込むため、遅延はマイクと比べられない

再現のコマンド（リポジトリのルートで実行。音声の作り方は macOS の比較の再現手順を参照）：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
D=<iPhone の UDID>; BID=<Local.xcconfig の PRODUCT_BUNDLE_IDENTIFIER>
xcodegen generate --spec Verification/iOSSTTProbe/project.yml
xcodebuild -project Verification/iOSSTTProbe/iOSSTTProbe.xcodeproj -scheme iOSSTTProbe -configuration Release \
  -destination "id=$D" -derivedDataPath "$TMPDIR/sttprobe-dd" -allowProvisioningUpdates build
xcrun devicectl device install app --device $D "$TMPDIR/sttprobe-dd/Build/Products/Release-iphoneos/iOSSTTProbe.app"

# 40件：評価セットと音声を AutoInput に置いて起動すると、認識して書き出す（初回は音声認識の許可を iPhone で押す）
mkdir -p "$TMPDIR/ios-in" && cp eval/audio/synthetic/{ja,mix,dev,num}-*.wav "$TMPDIR/ios-in/"
cp eval/synthetic-tts-set.json "$TMPDIR/ios-in/set.json"; echo '{"repeat":1,"wait":true}' > "$TMPDIR/ios-in/autorun.json"
xcrun devicectl device copy to --device $D --source "$TMPDIR/ios-in" --destination Documents/AutoInput \
  --domain-type appDataContainer --domain-identifier $BID
xcrun devicectl device process launch --device $D --terminate-existing $BID
# 成功すると Documents/ProbeOutput/auto-done.txt、失敗すると auto-failed.txt（理由入り）ができる。AutoInput は音声ごと消える
# 書き出したフォルダを取り出して集計する
xcrun devicectl device info files --device $D --domain-type appDataContainer --domain-identifier $BID --subdirectory Documents/ProbeOutput
xcrun devicectl device copy from --device $D --domain-type appDataContainer --domain-identifier $BID \
  --source Documents/ProbeOutput/<日時>/results.json --destination eval/device/<日付>-<機種>/results.json
swift run --package-path Packages/UtterEvaluation utter-eval eval/device/<日付>-<機種>/results.json

# 連続認識：long.wav（40件をつないだ 126.7 秒）と、id が long の評価セットを置き、{"repeat":230,"wait":false} で起動する
```

## 精度（40件）

| 区分 | CER | 用語正答率 |
|---|---:|---:|
| 日本語（n=164） | 2.4% | — |
| 日英混在（n=201） | 39.8% | 14.3%（n=14） |
| 開発用語（n=208） | 44.7% | 12.5%（n=16） |
| 数字（n=143） | 6.3% | — |
| 合計（n=716） | 26.0% | 13.3%（n=30） |

macOS 27.0.1（Apple M5）での SpeechAnalyzer の結果と、すべての区分で同じ値だった（同じモデル・同じ音声）。

## 速度・メモリ（40件）

| 項目 | 値 |
|---|---|
| モデル準備（`prepareToAnalyze`） | 1件目 179ms、2件目以降 中央値 51ms |
| 処理時間 | 中央値 58ms（50〜115ms）。実時間比 0.021（40件の合計） |
| 最初の確定結果まで（1件目） | 113ms |
| 自プロセスのメモリ（`phys_footprint`） | 認識前 約28.1MB、認識中の最大 28.6MB、終了 5 秒後 28.4MB |
| 使えるメモリ（`os_proc_available_memory`） | 最小 3,347MB |
| 熱状態 | 全件 `nominal` |

- 推論の大半は OS のプロセスで動くため、自プロセスのメモリはほとんど増えない（macOS と同じ）。OS 側のメモリは今回測っていない（Instruments が要る）

## 連続認識（126.7 秒の音声を230回、約9分）

126.7 秒の音声を、待たずに230回続けて認識した（11:47〜11:57 UTC）。**1回あたり約2.5秒で処理するので、実時間で話す使い方の約50倍の負荷になる。**

| 項目 | 値 |
|---|---|
| 成功 | 230 / 230 回（中断・エラーなし、出力の文字数はすべて同じ） |
| 熱状態の推移 | 開始時 `nominal` → 86 秒後 `fair` → 416 秒後 `serious`（終了まで `serious`） |
| 処理時間 | 最初の10回 中央値 1.62 秒 → 最後の10回 中央値 2.81 秒（実時間比 0.013 → 0.022） |
| 自プロセスのメモリ | 27.7〜29.9MB（増え続けない） |

- 熱状態が上がるのに合わせて処理時間が延びた。熱で処理が絞られた（スロットリング）と見られる（推測）
- 充電しながら・画面を点けたまま測ったため、熱は充電の発熱も含む。電池の減りは測れていない

## 判断材料として言えること

- iPhone 17 Pro・iOS 27.2 では、SpeechAnalyzer（`SpeechTranscriber`）で日本語を端末内で認識でき、精度は macOS と同じだった
- 本体アプリのメモリは約30MB で、手順書の期待値（ピーク 2GB 未満）を大きく下回る（OS 側を除く）
- 実時間の50倍の連続負荷では約7分で `serious` になった。実際の使い方（実時間の録音）での10分連続使用の熱は、マイクで測る必要がある

## 測れていないこと

- 人の声・マイク入力での精度と遅延（録音開始遅延・停止→確定）
- 実時間（マイク）での10分連続使用の熱と、ケーブルを外した状態での電池の減り
- OS 側の認識プロセスのメモリ（Instruments）
- キーボード拡張のメモリ（iOS-PERF-01 / 05）
- 古い機種・メモリの少ない機種、iOS 26.x での動作（最低対応バージョンの判断）
