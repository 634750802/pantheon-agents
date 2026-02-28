#!/bin/bash

set -e

# Check if the number of arguments is less than 2
if [[ $# -lt 2 ]]; then
    echo "Error: Required argument is missing." >&2
    echo "Usage: $0 <role> <skills> [prototype-url]" >&2
    echo "  \`skills\` is a comma-separated string"
    echo "  \`prototype-url\` is default to https://github.com/pingcap-inc/pantheon-agents"
    exit 1
fi

WORK_DIR="$(pwd)"

ROLE="$1"
SKILLS="$2"
PROTOTYPE_REPO="${3:-https://github.com/pingcap-inc/pantheon-agents}"

# Create claude dir
mkdir -p "${WORK_DIR}/.claude"

echo Pantheon Agent: Setup "$ROLE" from "$PROTOTYPE_REPO" with skills: "$SKILLS"

# Print the version
echo "Pantheon Agent: Installed claude code $(claude --version)"

PROTOTYPE_DIR=$(mktemp -d)

echo "Pantheon Agent: Cloning prototype repo into $PROTOTYPE_DIR"

git clone "$PROTOTYPE_REPO" --depth 1 "$PROTOTYPE_DIR" 2>/dev/null

function copy_file_or_directory () {
  local SOURCE="$PROTOTYPE_DIR/$1"
  local TARGET="$WORK_DIR/$2"

  if [[ -f "$TARGET" ]]; then
    rm -f "$TARGET"
  elif [[ -d "$TARGET" ]]; then
    rm -r "$TARGET"
  fi

  if [[ -f "$SOURCE" ]]; then
    cp "$SOURCE" "$TARGET"
  elif [[ -d "$SOURCE" ]]; then
    cp -r "$SOURCE" "$TARGET"
  else
    echo "$SOURCE not exists."
    exit 1
  fi
}

echo Pantheon Agent: Copying CLAUDE.md
copy_file_or_directory "agents/$ROLE/AGENTS.md" "CLAUDE.md"

mkdir -p "$WORK_DIR/.claude/skills"

IFS=',' read -r -a SKILL_ARRAY <<< "$SKILLS"

for skill in "${SKILL_ARRAY[@]}"; do
  skill="${skill//[[:space:]]/}"
  if [[ -z "$skill" ]]; then
    echo "Error: empty skill name in '$SKILLS'" >&2
    exit 1
  fi

  echo Pantheon Agent: Copying skills/$skill
  copy_file_or_directory "skills/$skill" ".claude/skills/$skill"
done
