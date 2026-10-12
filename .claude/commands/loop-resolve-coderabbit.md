---
allowed-tools: Bash(git:*), Bash(gh:*), Bash(pnpm:*), Read, Write, Edit, Glob, Grep
argument-hint: [PR番号]
description: Loop PRのCodeRabbit指摘を分類して対応する
---

## タスク

指定されたLoop PR（または優先度が最も高い対象Loop PR）のCodeRabbitレビューthreadを調べます。対象リポジトリ、open状態、`develop` がbaseであること、信頼できる作成者であること、人対応・blockedラベルがないことを確認します。CodeRabbitのレート制限で最新commitが未レビューの場合も、残っている未解決threadは通常どおり対応します。

対応が必要な指摘をすべて、**修正**、**理由を示して見送る**、**別Issueにする** のいずれかに分類します。判断前に現在のコードとテストを確認し、ゲートを通すためだけに指摘を退けてはいけません。人が書いたレビュー依頼は維持し、本人に代わってthreadをresolveしてはいけません。

修正する場合はPRのheadから分離したworktreeを作り、必要な箇所だけを変更し、`pnpm verify` と関連する個別チェックを実行してからpushします。見送る場合は、技術的な理由を簡潔にPRへ投稿します。対象外の指摘は `loop:human` を付けた別Issueにします。書き込み前にリモートの状態を再確認します。修正は1回で止め、不確かな場合は `loop:human` を付けてブロッカーを説明します。

CI修正とCodeRabbit修正を合わせ、PRごとの修正pushは最大3回です。各修正pushの後に `loop:repair-1`、`loop:repair-2`、`loop:repair-3` のうち1つだけを付け、回数を更新します。3回目は `loop:human` も付けます。maintainerが明示的に `loop:human` と回数ラベルを外さない限り、追加の自動修正をしてはいけません。
