#!/usr/bin/env bash
# Add the current scripts directory to ~/.bashrc PATH.
set -Eeuo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "$SCRIPT_PATH")"
# shellcheck source=lib/self_update.sh
source "${SCRIPT_DIR}/lib/self_update.sh"
scripts_self_update "$SCRIPT_DIR" "$SCRIPT_PATH" "$@"

TARGET_DIR="${1:-$(pwd -P)}"
BASHRC="${HOME}/.bashrc"
ENV_VAR_NAME="USER_SCRIPTS_DIR"
START_MARKER="# >>> user scripts path >>>"
END_MARKER="# <<< user scripts path <<<"

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: directory does not exist: $TARGET_DIR" >&2
  exit 1
fi

TARGET_DIR="$(cd "$TARGET_DIR" && pwd -P)"
ESCAPED_TARGET_DIR="${TARGET_DIR//\\/\\\\}"
ESCAPED_TARGET_DIR="${ESCAPED_TARGET_DIR//\"/\\\"}"

touch "$BASHRC"
tmp_file="$(mktemp)"

awk -v start="$START_MARKER" -v end="$END_MARKER" '
  $0 == start { skip = 1; next }
  $0 == end { skip = 0; next }
  !skip { print }
' "$BASHRC" > "$tmp_file"

cat >> "$tmp_file" <<EOF

$START_MARKER
export ${ENV_VAR_NAME}="${ESCAPED_TARGET_DIR}"
case ":\$PATH:" in
  *":\$${ENV_VAR_NAME}:"*) ;;
  *) export PATH="\$${ENV_VAR_NAME}:\$PATH" ;;
esac
if [[ \$- == *i* ]]; then
  for completion_file in "\$${ENV_VAR_NAME}"/completions/*.bash; do
    [[ -r "\$completion_file" ]] && source "\$completion_file"
  done
fi
$END_MARKER
EOF

mv "$tmp_file" "$BASHRC"

echo "Updated PATH config in $BASHRC:"
echo "  $TARGET_DIR"
echo "Bash completions are loaded from:"
echo "  $TARGET_DIR/completions/*.bash"
echo
echo "Run this once in the current shell:"
echo "  source ~/.bashrc"
