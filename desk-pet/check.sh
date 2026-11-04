#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
mkdir -p .build/checks .build/module-cache
python3 - <<'PY'
from pathlib import Path
source = Path('PixelDrawing.swift').read_text()+'\n'+Path('Play.swift').read_text()+'\n'+Path('Meeting.swift').read_text()+'\n'+Path('Landing.swift').read_text()+'\n'+Path('UserPlay.swift').read_text()+'\n'+Path('DeskPet.swift').read_text().split('// Entry point (')[0]
Path('.build/DeskPetChecks.swift').write_text(source + '\n' + Path('OffscreenChecks.swift').read_text()+'\n'+Path('PixelArtChecks.swift').read_text()+'\n'+Path('QuotaRegressionChecks.swift').read_text()+'\n'+Path('MeetingChecks.swift').read_text()+'\n'+Path('../codex-pet/Task9Checks.swift').read_text()+'\n'+Path('LandingChecks.swift').read_text()+'\n'+Path('PlayChecks.swift').read_text()+'\n'+Path('UserPlayChecks.swift').read_text())
PY
swiftc -D MEETING_CHECKS -D DESK_PET -O -swift-version 5 -target arm64-apple-macosx18.0 \
  -module-cache-path "$PWD/.build/module-cache" \
  .build/DeskPetChecks.swift -o .build/checks/run
.build/checks/run "$PWD/.build/checks" "$PWD/gallery-acts.png" "$PWD/gallery-costumes.png"

../codex-pet/check-meeting-geometry.sh "$PWD/.build/checks/meeting-geometry"
