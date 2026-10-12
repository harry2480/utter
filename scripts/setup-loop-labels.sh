#!/usr/bin/env bash
set -euo pipefail

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "先に、このリポジトリへの書き込み権限があるGitHub CLIで認証してください。" >&2
  exit 1
fi

repository="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

create_or_update_label() {
  local name="$1"
  local color="$2"
  local description="$3"
  gh label create "$name" --repo "$repository" --color "$color" --description "$description" --force
}

create_or_update_label "loop:ready" "0E8A16" "Loopでの実装が承認された、範囲の明確なIssue"
create_or_update_label "loop:wip" "1D76DB" "LoopがこのIssueまたはPRを処理中"
create_or_update_label "loop:blocked" "B60205" "外部要因が解消するまでLoopを継続できない"
create_or_update_label "loop:human" "D93F0B" "人による判断または作業が必要"
create_or_update_label "loop:unblock" "FBCA04" "blockedのIssueをLoopに再確認させる"
create_or_update_label "loop:repair-1" "C5DEF5" "このPRに対して自動修正pushを1回実行済み"
create_or_update_label "loop:repair-2" "BFD4F2" "このPRに対して自動修正pushを2回実行済み"
create_or_update_label "loop:repair-3" "F9D0C4" "修正pushの上限に達したため人の確認が必要"
