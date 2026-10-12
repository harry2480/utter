---
allowed-tools: Bash(git:*), Bash(gh:*), Bash(pnpm:*), Read, Write, Edit, Glob, Grep
argument-hint: [PR番号]
description: Loop PRのCI失敗を調査して修復する
---

## タスク

対象となるLoop PRの失敗したチェックを調べます。PRがopenで、baseが `develop` であり、このリポジトリに属し、blockedや人の対応待ちではないことを確認します。

チェックログと現在の差分から原因を特定します。古い実行結果から原因を推測してはいけません。PRが原因の失敗だけを修正します。インフラの不安定さ、認証情報の不足、外部サービス障害、原因不明の失敗では製品コードを変更せず、PRとIssueに `loop:human` を付けて根拠を報告します。

分離したworktreeで焦点を絞った修正を1回だけpushします。`pnpm verify` と該当する失敗チェックをローカルで実行します。ビルド失敗の場合、破棄可能なPostgreSQLが用意できるときだけmigration適用後に `pnpm build` を実行し、個人用・本番DBは使いません。ローカルで再現できない場合はその旨を記録し、CI結果で確認します。push前にPRのheadを再確認し、変わっていれば停止します。CIを回避したりmergeしたりしてはいけません。失敗内容、修正、検証結果、残るブロッカーを報告します。

CI修正とCodeRabbit修正を合わせ、PRごとの修正pushは最大3回です。各修正pushの後に `loop:repair-1`、`loop:repair-2`、`loop:repair-3` のうち1つだけを付け、回数を更新します。3回目は `loop:human` も付けます。maintainerが明示的に `loop:human` と回数ラベルを外さない限り、追加の自動修正をしてはいけません。
