#!/usr/bin/env bash
# Point ~/dev/SplunkMiningDemoApp at this project's Cursor agent store.
# No account id, access key, password, token, or license is stored here.
set -euo pipefail

dest="${HOME}/dev/SplunkMiningDemoApp"
roots=(
  "${HOME}/Library/Application Support/Cursor/AgentStores/cursor_agent_stores"
  "${HOME}/Library/Application Support/Cursor/AgentStores"
)
preferred="bc-8cbf050b-5bbd-43bd-8eb9-5b325beb8544"
found=""

for root in "${roots[@]}"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r script; do
    [[ -n "$script" ]] || continue
    if [[ "$script" == *"/${preferred}/"* ]]; then
      found=$script
      break
    fi
    if [[ -z "$found" ]]; then
      found=$script
    fi
  done < <(find "$root" -maxdepth 6 -type f -path '*/files/docs/aws/setup-splunk-enterprise.sh' 2>/dev/null)
  [[ -n "$found" ]] && break
done

[[ -n "$found" ]] || {
  printf 'error: no docs/aws/setup-splunk-enterprise.sh under Cursor AgentStores.\n' >&2
  exit 1
}

files=$(CDPATH='' cd -- "$(dirname -- "$found")/../.." && pwd)
mkdir -p "${HOME}/dev"
if [[ -e "$dest" && ! -L "$dest" ]]; then
  printf 'error: %s exists and is not a symlink. Move it aside, then run this again.\n' "$dest" >&2
  exit 1
fi
ln -sfn "$files" "$dest"
printf '%s -> %s\n' "$dest" "$files"
printf 'Scripts: %s\n' "${dest}/docs/aws"
