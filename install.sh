#!/usr/bin/env bash
# One-line installer: copies every skill in this repo into ~/.claude/skills/
#   curl -fsSL https://raw.githubusercontent.com/tiantaiyang/claude-skills/main/install.sh | bash
set -euo pipefail

REPO="tiantaiyang/claude-skills"
BRANCH="${CLAUDE_SKILLS_BRANCH:-main}"
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading ${REPO}@${BRANCH} ..."
curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" | tar -xz -C "$TMP"

SRC="$TMP/claude-skills-${BRANCH}/skills"
if [ ! -d "$SRC" ]; then
  echo "ERROR: no skills/ directory found in the downloaded archive." >&2
  exit 1
fi

mkdir -p "$DEST"
installed=0
for dir in "$SRC"/*/; do
  name="$(basename "$dir")"
  if [ ! -f "$dir/SKILL.md" ]; then
    echo "Skipping $name (no SKILL.md)"
    continue
  fi
  rm -rf "${DEST:?}/${name}"
  cp -R "$dir" "$DEST/$name"
  echo "Installed skill: $name -> $DEST/$name"
  installed=$((installed + 1))
done

echo ""
echo "Done ($installed skill(s) installed)."
echo "Restart Claude Code or start a new session to pick them up."
