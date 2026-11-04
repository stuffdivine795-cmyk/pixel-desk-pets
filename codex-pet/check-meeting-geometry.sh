#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
geometry_dir="$1"
mkdir -p "$geometry_dir"
python3 - "$geometry_dir" <<'PY'
from pathlib import Path
import sys
out=Path(sys.argv[1])
shared='\n'.join(Path(p).read_text() for p in ['PixelDrawing.swift','Play.swift','Meeting.swift','Landing.swift','UserPlay.swift'])
for role,source in [('claude','../desk-pet/DeskPet.swift'),('codex','CodexPet.swift')]:
 (out/(role+'.swift')).write_text(shared+'\n'+Path(source).read_text().split('// Entry point (')[0]+'\n'+Path('MeetingGeometryChecks.swift').read_text()+'\n'+Path('Task11Checks.swift').read_text()+'\n'+Path('PlayGeometryChecks.swift').read_text())
PY
for role in claude codex; do
  flags=()
  if [[ "$role" == claude ]]; then flags=(-D DESK_PET); fi
  swiftc -D MEETING_CHECKS "${flags[@]}" -O -swift-version 5 -target arm64-apple-macosx18.0 \
    -module-cache-path "$PWD/.build/module-cache" "$geometry_dir/$role.swift" -o "$geometry_dir/$role"
  "$geometry_dir/$role" export "$geometry_dir"
done
"$geometry_dir/claude" rows "$geometry_dir"
"$geometry_dir/codex" rows "$geometry_dir"
"$geometry_dir/claude" verify "$geometry_dir"
"$geometry_dir/codex" verify "$geometry_dir"

"$geometry_dir/claude" play-export "$geometry_dir"
"$geometry_dir/codex" play-export "$geometry_dir"
"$geometry_dir/claude" play-verify "$geometry_dir"
"$geometry_dir/codex" play-verify "$geometry_dir"
"$geometry_dir/claude" play-compose "$geometry_dir"
