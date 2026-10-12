#!/bin/bash

# Merge PR and delete local/remote branches
# Usage: pnpm merge [PR_NUMBER_OR_URL]

set -e

# Get PR number from argument or detect current branch
if [ -z "$1" ]; then
  # No argument: merge current branch's PR
  gh pr merge --delete-branch -s
else
  # With argument: merge specified PR
  gh pr merge "$1" --delete-branch -s
fi

# Clean up remote tracking branches
git fetch --prune
