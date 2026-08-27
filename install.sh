#!/usr/bin/env bash
# One-line installer: copies skills from this repo into ~/.claude/skills/
# (and ~/.cursor/skills if Cursor is present).
#   curl -fsSL https://github.com/tiantaiyang/claude-skills/raw/refs/heads/main/install.sh | bash
#   curl -fsSL https://github.com/tiantaiyang/claude-skills/raw/refs/heads/main/install.sh | bash -s commit-pr
set -euo pipefail

REPO="tiantaiyang/claude-skills"
BRANCH="${CLAUDE_SKILLS_BRANCH:-main}"
WANTED=()
DESTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --cursor)
      DESTS=("$HOME/.cursor/skills")
      shift
      ;;
    --dest)
      if [ $# -lt 2 ]; then
        echo "ERROR: --dest requires a path" >&2
        exit 1
      fi
      DESTS=("$2")
      shift 2
      ;;
    --help|-h)
      echo "Usage: bash -s [--cursor] [--dest DIR] [skill-name ...]"
      echo "  no skill names  install every skill"
      echo "  default dests   ~/.claude/skills, and ~/.cursor/skills if ~/.cursor exists"
      echo "  --cursor        install only into ~/.cursor/skills"
      echo "  --dest DIR      install only into DIR"
      exit 0
      ;;
    --)
      shift
      WANTED+=("$@")
      break
      ;;
    -*)
      echo "ERROR: unknown flag: $1" >&2
      echo "Usage: bash -s [--cursor] [--dest DIR] [skill-name ...]" >&2
      exit 1
      ;;
    *)
      WANTED+=("$1")
      shift
      ;;
  esac
done

if [ ${#DESTS[@]} -eq 0 ]; then
  if [ -n "${CLAUDE_SKILLS_DIR:-}" ]; then
    DESTS=("$CLAUDE_SKILLS_DIR")
  else
    DESTS=("$HOME/.claude/skills")
    if [ -d "$HOME/.cursor" ]; then
      DESTS+=("$HOME/.cursor/skills")
    fi
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading ${REPO}@${BRANCH} ..."
curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/${BRANCH}" | tar -xz -C "$TMP"

SRC="$TMP/claude-skills-${BRANCH}/skills"
if [ ! -d "$SRC" ]; then
  echo "ERROR: no skills/ directory found in the downloaded archive." >&2
  exit 1
fi

available=()
for dir in "$SRC"/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  [ -f "$dir/SKILL.md" ] || continue
  available+=("$name")
done

if [ ${#available[@]} -eq 0 ]; then
  echo "ERROR: no skills with SKILL.md found in the archive." >&2
  exit 1
fi

if [ ${#WANTED[@]} -gt 0 ]; then
  missing=()
  for w in "${WANTED[@]}"; do
    found=0
    for a in "${available[@]}"; do
      if [ "$a" = "$w" ]; then
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      missing+=("$w")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: unknown skill(s): ${missing[*]}" >&2
    echo "Available: ${available[*]}" >&2
    exit 1
  fi
fi

should_install() {
  local name="$1"
  if [ ${#WANTED[@]} -eq 0 ]; then
    return 0
  fi
  local w
  for w in "${WANTED[@]}"; do
    if [ "$w" = "$name" ]; then
      return 0
    fi
  done
  return 1
}

installed=0
for DEST in "${DESTS[@]}"; do
  mkdir -p "$DEST"
  for name in "${available[@]}"; do
    if ! should_install "$name"; then
      continue
    fi
    rm -rf "${DEST:?}/${name}"
    cp -R "$SRC/$name" "$DEST/$name"
    echo "Installed skill: $name -> $DEST/$name"
    installed=$((installed + 1))
  done
done

echo ""
echo "Done ($installed copy(ies) installed)."
echo "Restart Claude Code / Cursor or start a new session to pick them up."
