#!/usr/bin/env bash
# ============================================================
#  push.sh  —  initialize + push CLAWTANK to GitHub
#  Run from your project root (folder with main.py).
# ============================================================
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -f "main.py" ]; then
  echo "!! main.py not found in $(pwd) — cd into your project folder first"
  exit 1
fi

# ---------- 1. make sure .gitignore is sane ----------
if [ ! -f ".gitignore" ]; then
  echo "  writing .gitignore"
  cat > .gitignore << '__EOF__'
venv/
__pycache__/
*.pyc
.env
.DS_Store
*.log
__EOF__
else
  echo "  .gitignore already exists — leaving it alone"
fi

# ---------- 2. git init if needed ----------
if [ ! -d ".git" ]; then
  echo "  initializing git repo"
  git init
  git branch -M main
else
  echo "  git repo already initialized"
fi

# ---------- 3. stage + commit ----------
git add -A

if git diff --cached --quiet; then
  echo "  nothing new to commit"
else
  read -r -p "  Commit message [update CLAWTANK]: " MSG
  MSG="${MSG:-update CLAWTANK}"
  git commit -m "$MSG"
fi

# ---------- 4. ask for remote ----------
CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null || true)

if [ -z "$CURRENT_REMOTE" ]; then
  echo ""
  echo "  Paste your GitHub repo URL."
  echo "  Example:  https://github.com/yourname/clawtank.git"
  read -r -p "  Remote: " REMOTE
  if [ -z "$REMOTE" ]; then
    echo "!! no remote given, stopping"
    exit 1
  fi
  git remote add origin "$REMOTE"
else
  echo "  origin already set to: $CURRENT_REMOTE"
fi

# ---------- 5. push ----------
echo ""
echo "  Pushing to origin main..."
echo "  (GitHub will ask for your username and a Personal Access Token as password)"
echo ""
git push -u origin main

echo ""
echo "=================================================="
echo "  PUSHED"
echo "=================================================="
echo ""
git log --oneline -1
echo ""
git remote -v
echo ""
