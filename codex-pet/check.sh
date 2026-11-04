#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
mkdir -p .build/checks .build/module-cache
./generate_geometry.py --check
python3 - <<'PY'
from pathlib import Path
shared=Path('PixelDrawing.swift').read_text()+'\n'+Path('Play.swift').read_text()+'\n'+Path('Meeting.swift').read_text()+'\n'+Path('Landing.swift').read_text()+'\n'+Path('UserPlay.swift').read_text()+'\n'
source=shared+Path('CodexPet.swift').read_text().split('// Entry point (')[0]
Path('.build/CodexPetChecks.swift').write_text(source+'\n'+Path('OffscreenChecks.swift').read_text()+'\n'+Path('PixelArtChecks.swift').read_text()+'\n'+Path('PairPreviewChecks.swift').read_text()+'\n'+Path('MeetingChecks.swift').read_text()+'\n'+Path('Task9Checks.swift').read_text()+'\n'+Path('LandingChecks.swift').read_text()+'\n'+Path('PlayChecks.swift').read_text()+'\n'+Path('UserPlayChecks.swift').read_text())
source=shared+Path('../desk-pet/DeskPet.swift').read_text().split('// Entry point (')[0]
Path('.build/DeskBatteryChecks.swift').write_text(source+'\n'+Path('DeskBatteryChecks.swift').read_text()+'\n'+Path('PairPreviewChecks.swift').read_text())
PY
swiftc -D MEETING_CHECKS -O -swift-version 5 -target arm64-apple-macosx18.0 \
  -module-cache-path "$PWD/.build/module-cache" .build/CodexPetChecks.swift -o .build/checks/codex
.build/checks/codex "$PWD/.build/checks" "$PWD/gallery.png" "$PWD/.build/checks"
swiftc -D MEETING_CHECKS -D DESK_PET -O -swift-version 5 -target arm64-apple-macosx18.0 \
  -module-cache-path "$PWD/.build/module-cache" .build/DeskBatteryChecks.swift -o .build/checks/desk-battery
.build/checks/desk-battery "$PWD/../desk-pet/gallery-battery.png" "$PWD/.build/checks"

./check-meeting-geometry.sh "$PWD/.build/checks/meeting-geometry"
