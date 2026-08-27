#!/usr/bin/env bash
# One-line installer: copies skills from this repo into ~/.claude/skills/
#   curl -fsSL https://raw.githubusercontent.com/tiantaiyang/claude-skills/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/tiantaiyang/claude-skills/main/install.sh | bash -s commit-pr
#   curl -fsSL https://raw.githubusercontent.com/tiantaiyang/claude-skills/main/install.sh | bash -s commit-pr --cursor
set -euo pipefail

REPO="tiantaiyang/claude-skills"
BRANCH="${CLAUDE_SKILLS_BRANCH:-main}"
DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
WANTED=()

while [ $# -gt 0 ]; do
  case "$1" in
    --cursor)
      DEST="$HOME/.cursor/skills"
      shift
      ;;
    --dest)
      if [ $# -lt 2 ]; then
        echo "ERROR: --dest requires a path" >&2
        exit 1
      fi
      DEST="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: bash -s [--cursor] [--dest DIR] [skill-name ...]"
      echo "  no skill names  install every skill"
      echo "  --cursor        install into ~/.cursor/skills"
      echo "  --dest DIR      install into DIR (overrides --cursor)"
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading ${REPO}@${BRANCH} ..."
curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" | tar -xz -C "$TMP"

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

mkdir -p "$DEST"
installed=0
for name in "${available[@]}"; do
  if ! should_install "$name"; then
    continue
  fi
  rm -rf "${DEST:?}/${name}"
  cp -R "$SRC/$name" "$DEST/$name"
  echo "Installed skill: $name -> $DEST/$name"
  installed=$((installed + 1))
done

echo ""
echo "Done ($installed skill(s) installed to $DEST)."
echo "Restart Claude Code / Cursor or start a new session to pick them up."
