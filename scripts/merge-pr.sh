#!/bin/bash

# Merge PR with a merge commit (squash is prohibited) and delete local/remote branches
# Usage: scripts/merge-pr.sh [PR_NUMBER_OR_URL]

set -e

# Get PR number from argument or detect current branch
if [ -z "$1" ]; then
  # No argument: merge current branch's PR
  gh pr merge --delete-branch --merge
else
  # With argument: merge specified PR
  gh pr merge "$1" --delete-branch --merge
fi

# Clean up remote tracking branches
git fetch --prune
