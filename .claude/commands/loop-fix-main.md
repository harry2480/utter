---
allowed-tools: Bash(git:*), Bash(gh:*), Bash(pnpm:*), Read, Write, Edit, Glob, Grep
argument-hint: <障害またはIssue>
description: develop上の障害修正をLoop外の承認付きで準備する
---

## タスク

このコマンドは人の依頼でのみ実行します。報告された `develop` 上の障害を調べ、範囲を絞ったIssueとfeature branchを作り、`develop` 向けPRを開きます。`develop` や `main` へ直接pushしてはいけません。本番環境に影響する操作にはmaintainerの承認が必要です。`pnpm verify` を実行し、根拠を記録して、PR作成後に終了します。
