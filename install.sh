#!/bin/zsh
# Build both pets, install the default lines (never overwriting yours), and start them.
set -euo pipefail
cd -- "${0:A:h}"

mkdir -p ~/.claude/pet
for f in lines/*.json; do
  target=~/.claude/pet/${f:t}
  [[ -e $target ]] || cp "$f" "$target"
done

(cd desk-pet && ./build.sh)
(cd codex-pet && ./build.sh)

pkill -x DeskPet 2>/dev/null || true
pkill -x CodexPet 2>/dev/null || true
open desk-pet/DeskPet.app
open codex-pet/CodexPet.app
echo "两只桌宠已启动。"
