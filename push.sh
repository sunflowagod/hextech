#!/usr/bin/env bash
# ============================================================
#  push.sh — force-push this folder to GitHub, overwriting
#            whatever is on the remote. Local is the truth.
#
#  Usage:
#    cd ~/Desktop/play/clawtank-studio
#    ./push.sh
#
#  Optional:
#    MSG="my message" ./push.sh
# ============================================================
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"
REPO_URL="https://github.com/sunflowagod/clawtank.git"

echo ""
echo "  working dir : $(pwd)"
echo "  remote      : $REMOTE"
echo "  branch      : $BRANCH"
echo ""

# ---------- init repo if needed ----------
if [ ! -d .git ]; then
  echo "  git init"
  git init -q
  git branch -M "$BRANCH"
fi

# ---------- ensure origin ----------
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "  setting $REMOTE → $REPO_URL"
  git remote add "$REMOTE" "$REPO_URL"
else
  echo "  $REMOTE already set: $(git remote get-url "$REMOTE")"
  # in case origin points somewhere else, fix it
  git remote set-url "$REMOTE" "$REPO_URL"
fi

# ---------- stage everything ----------
git add -A .
git add -f . 2>/dev/null || true

# ---------- unstage junk ----------
for junk in venv .venv __pycache__ node_modules .pytest_cache; do
  git reset -q -- "$junk" 2>/dev/null || true
done

# ---------- commit ----------
echo ""
if git diff --cached --quiet; then
  echo "  nothing to commit"
else
  echo "  staged:"
  git diff --cached --name-only | sed 's/^/    /'
  echo ""
  MSG="${MSG:-update $(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  git -c user.name="${GIT_NAME:-$(git config user.name || echo clawtank)}" \
      -c user.email="${GIT_EMAIL:-$(git config user.email || echo clawtank@local)}" \
      commit -q -m "$MSG"
  echo "  committed: $MSG"
fi

# ---------- force-push ----------
# This is the whole point: overwrite remote with local history.
# --force-with-lease is safer than --force but still destructive.
echo ""
echo "  FORCE-pushing to $REMOTE/$BRANCH"
echo "  (this overwrites whatever is on GitHub)"
echo "  (GitHub asks for username + Personal Access Token)"
echo ""

git push --force "$REMOTE" "$BRANCH"

echo ""
echo "=================================================="
echo "  PUSHED (forced)"
echo "=================================================="
echo ""
git log --oneline -3
echo ""
git remote -v
echo ""
