// Appended to both real native view/model check executables. No app/window or real preferences.
let landingCheckStart = checks
let landingRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let landingTestRoot = landingRoot.appendingPathComponent(".build/checks/landing")
try FileManager.default.createDirectory(at: landingTestRoot,withIntermediateDirectories: true)
let landingTestLines = SpeechLines(url: landingTestRoot.appendingPathComponent("no-lines.json"))
func landingModel() -> PetModel {
    let m = PetModel(frame: CGRect(x: 0,y: 0,width: 1600,height: 1200),lines: landingTestLines,now: 1000,preferences: MemoryDefaults())
    m.quiet = true;m.nextAct = 1e9;m.nextPause = 1e9;m.chooseOutfit(.none)
    m.landingLines = LandingLines(url: landingTestRoot.appendingPathComponent("landing-lines.json"))
    return m
}
let landingRole = MeetingRole.local
let landingKinds = LandingTrick.general(landingRole,height: 500) + (landingRole == .claude ? [.broom,.party_balloons] : [.umbrella,.lotus,.duck,.ice])
func landingOutfit(_ kind: LandingTrick) -> Outfit {
    #if DESK_PET
    return kind == .broom ? .witch : kind == .party_balloons ? .party : .none
    #else
    return Outfit(rawValue: kind.rawValue) ?? .none
    #endif
}
for size in PetSize.allCases {
    let m = landingModel();m.chooseSize(size)
    for (height,expected): (CGFloat,LandingTrick?) in [(0,nil),(79.999,nil),(80,.light),(219.999,.light),(220,.parachute),(399.999,.parachute),(400,.parachute)] {
        m.lastLanding = nil;m.position.y = m.floor+height*m.landingScale;m.dragging = true
        m.releaseDrag(now: 1000)
        if height < 220 { check(m.landing?.kind == expected,"exact height threshold scales with UI size") }
        else { check(m.landing != nil && m.landing?.kind != .light,"220 points uses a high trick") }
        m.beginDrag(now: 1001)
        check(m.landing == nil && m.trick == nil && m.velocityY == 0,"re-drag removes physics, effect and click trick")
    }
}
for role in MeetingRole.allCases {
    for h: CGFloat in [220,399.99,400,900] {
        for outfit in ["none","witch","party","umbrella","lotus","duck","ice","goggles"] {
            var last: LandingTrick?
            for _ in 0..<100 {
                let choice = LandingTrick.pick(role: role,height: h,outfit: outfit,last: last)!
                check(choice != last,"no immediately repeated high trick")
                check(choice != .jetpack || (h >= 400 && role == .claude),"jetpack only very high")
                check(LandingTrick.general(role,height: h).contains(choice) || LandingTrick.signature(role,outfit: outfit) == choice,"outfit-only effects require that outfit")
                last = choice
            }
            if let special = LandingTrick.signature(role,outfit: outfit) {
                for i in 0..<100 {
                    let choice = LandingTrick.pick(role: role,height: h,outfit: outfit,last: nil,roll: { Double(i)/100 },index: { _ in 0 })
                    check((choice == special) == (i < 70),"exact 70 percent eligible outfit preference")
                }
            }
        }
    }
}
// Missing, malformed, empty and partially provided line groups all have usable fallback text.
let lineReader = LandingLines(url: landingTestRoot.appendingPathComponent("custom.json"))
try? FileManager.default.removeItem(at: lineReader.url)
for kind in landingKinds {
    check(!lineReader.line(role: landingRole,kind: kind,landed: false).isEmpty,"missing start lines fallback")
    check(!lineReader.line(role: landingRole,kind: kind,landed: true).isEmpty,"missing land lines fallback")
}
let customLines = [landingRole.rawValue: [landingKinds[0].rawValue: ["start":["起飞测试"],"land":["落地测试"]]]]
try JSONEncoder().encode(customLines).write(to: lineReader.url,options: .atomic)
check(lineReader.line(role: landingRole,kind: landingKinds[0],landed: false) == "起飞测试","custom start line")
check(lineReader.line(role: landingRole,kind: landingKinds[0],landed: true) == "落地测试","custom land line")
try Data("broken".utf8).write(to: lineReader.url)
check(!lineReader.line(role: landingRole,kind: landingKinds[0],landed: true).isEmpty,"malformed line file fallback")
// Exercise complete physics for every effect and size, rather than just drawing injected poses.
for size in PetSize.allCases { for kind in [.light]+landingKinds {
    let m = landingModel();m.chooseSize(size);m.chooseOutfit(landingOutfit(kind));m.actIndex = 0;m.nextAct = 1e9;m.direction = 1
    m.position = CGPoint(x: 500,y: m.floor+500*m.landingScale)
    m.beginLanding(height: 500*m.landingScale,now: 1000)
    m.landing = LandingRun(kind: kind,started: 1000,height: 500*m.landingScale,originX: 500,direction: 1)
    let v = PetView(model: m)
    check(!v.quotaPlateVisible,"quota hidden at release")
    var protectedDistance: CGFloat = 0,protectedTime = 0.0,lastY = m.position.y
    var firstContact: Double?,contactX: CGFloat = 0
    for frame in 1...720 {
        let now = 1000+Double(frame)/60
        let wasAir = m.landing?.landedAt == nil
        m.step(dt: 1.0/60,now: now);v.time = now
        if wasAir && m.landing?.landedAt == nil && now > 1000.25 && kind.protected {
            protectedDistance += lastY-m.position.y;protectedTime += 1.0/60
        }
        lastY = m.position.y
        if m.landing?.landedAt == nil && m.landing != nil { check(!v.quotaPlateVisible,"plate hidden for every airborne frame") }
        if let run = m.landing,run.landedAt != nil,firstContact == nil {
            firstContact = run.landedAt;contactX = m.position.x
            if kind != .light { check(abs(m.speechUntil-now-2) < 0.001 && !m.speech.isEmpty,"landing line lasts two seconds") }
        }
        if m.landing == nil { break }
    }
    check(m.landing == nil && m.grounded,"every landing terminates at the floor")
    check(v.quotaPlateVisible,"quota restored after landing settles")
    if kind.protected {
        check(protectedTime > 0.5,"enough protected flight samples")
        let speed = protectedDistance/CGFloat(protectedTime)/m.landingScale
        check((90...140).contains(speed),"protected fall speed is 90-140 medium points per second")
    }
    if kind == .lotus { check(abs(contactX-500-60*m.landingScale) <= 1,"lotus drifts 60 scaled points before contact") }
    if kind == .ice { check(abs(m.position.x-contactX-60*m.landingScale) <= 1,"ice slides 60 scaled points after contact") }
    // Cancel from both protected flight and each settling effect; the next release starts cleanly.
    for landed in [false,true] {
        m.landing = LandingRun(kind: kind,started: 1000,height: 500,originX: 500,direction: 1,landedAt: landed ? 1001 : nil)
        m.beginDrag(now: 1001.2)
        check(m.landing == nil && m.speech.isEmpty,"re-drag cancels airborne and settled effects")
        m.position.y = m.floor+30*m.landingScale;m.releaseDrag(now: 1002)
        check(m.landing == nil,"short re-drop has no leftover effect")
    }
} }
#if DESK_PET
// Floor props must not follow the moving pet's unsnapped 60 Hz coordinates.
for size in PetSize.allCases { for kind: LandingTrick in [.box,.trampoline] {
    let m = landingModel();m.chooseSize(size)
    let v = PetView(model: m)
    let grid = PixelGrid(cell: size.uiCell)
    for lift in 1...18 {
        m.position.y = m.floor+CGFloat(lift)
        let snapped = grid.point(m.position)
        let origin = size.windowOrigin(position: snapped,in: m.visibleFrame)
        v.anchor = grid.point(CGPoint(x: snapped.x-origin.x,y: snapped.y-origin.y));v.time = 1001
        m.landing = LandingRun(kind: kind,started: 1000,height: 500,originX: 500,direction: 1)
        let props = v.landingSprite!.filter { !$0.interactive }
        let ground = props.map { $0.rect.minY+origin.y }.min()!
        let expected = grid.snap(m.floor)-(kind == .trampoline ? size.cell : 0)
        check(abs(ground-expected) < 0.001,"box/trampoline stays on the actual floor between snapped foot frames")
    }
} }
#endif

// A grab aborts the meeting, and landing cannot revive it or bypass the drag cooldown.
let landingMeetingDir = landingTestRoot.appendingPathComponent("cancelled-meeting")
let landingMeetingPet = landingModel()
let landingMeeting = MeetingCoordinator(directory: landingMeetingDir)
var landingEpoch = 4000000000.0
landingMeeting.epochNow = { landingEpoch };landingMeetingPet.meeting = landingMeeting
let landingOwn = landingMeeting.snapshot(landingMeetingPet,now: landingEpoch)
var landingPeer = landingOwn;landingPeer.x += 80
let interrupted = MeetingRules.plan(script: MeetingRules.fallbacks["both_idle"]!,situation: "both_idle",c: landingOwn,d: landingPeer,now: landingEpoch)
landingMeeting.setPreview(plan: interrupted)
landingMeetingPet.beginDrag(now: 1000)
check(landingMeeting.active == nil,"grabbing a meeting aborts it immediately")
landingMeetingPet.position.y = landingMeetingPet.floor+240
landingMeetingPet.releaseDrag(now: 1000)
for f in 1...600 {
    landingEpoch += 1.0/60;landingPeer.ts = landingEpoch
    landingPeer.busy = false;landingPeer.dragging = false;landingPeer.trick = false
    try JSONEncoder().encode(landingPeer).write(to: landingMeeting.peerURL,options: .atomic)
    landingMeetingPet.step(dt: 1.0/60,now: 1000+Double(f)/60)
    check(landingMeeting.active == nil,"landing never restarts the interrupted meeting")
    if f%60 == 0 {
        let published = try JSONDecoder().decode(MeetingPosition.self,from: Data(contentsOf: landingMeeting.ownURL))
        check(published.fresh(landingEpoch),"position heartbeat remains fresh during and after a landing")
        if landingMeetingPet.landing != nil { check(!published.ready,"a landing heartbeat is never ready for a meeting") }
    }
}

// Sweep all discrete trick frames, all sizes/outfits, both screen densities and intermediate times.
for density: CGFloat in [1,2] { for size in PetSize.allCases { for kind in [.light]+landingKinds { for outfit in Outfit.allCases {
    let restricted = LandingTrick.signature(landingRole,outfit: landingOutfit(kind).rawValue) == kind
    if restricted && outfit != landingOutfit(kind) { continue }
    let m = landingModel();m.chooseSize(size);m.chooseOutfit(outfit)
    let v = PetView(model: m);v.anchor = CGPoint(x: 240,y: 100)
    for landed in [false,true] { for frame in 0...96 {
        let t = Double(frame)/60
        m.position.y = m.floor+(landed ? 0 : 2*m.size.cell)
        let run = LandingRun(kind: kind,started: 1000,height: 500,originX: 500,direction: 1,landedAt: landed ? 1000 : nil)
        m.landing = run;v.time = 1000+t
        let base = v.landingSprite(pixelScale: density)!
        // Render natively at the requested backing scale; do not resample a different density.
        for p in base {
            check(p.color.alpha == 1,"landing visibility is binary")
            check(p.rect.width > 0 && p.rect.height > 0,"\(kind.rawValue) \(size.rawValue) density \(density) settled \(landed) frame \(frame): \(p.rect)")
            verifyPrimitive(p,density)
        }
        check(v.bounds.contains(base.filter(\.interactive).reduce(CGRect.null) { $0.union($1.rect) }),"interactive landing body fits native canvas")
    } }
} } } }
// Native PetView contact sheets: several falling/protected samples plus every re-form/settling step.
let landingSamples: [(Bool,Double)] = [(false,0),(false,0.08),(false,0.25),(false,0.375),(false,0.5),(false,0.625),
    (true,0),(true,0.25),(true,0.55),(true,0.82),(true,0.95),(true,1.08),(true,1.45),(true,1.55)]
let landingRows = [.light]+landingKinds
let landingTileW = 240,landingTileH = 360
let landingCanvas = pixelBitmap(landingTileW*landingSamples.count,landingTileH*landingRows.count)
landingCanvas.setFillColor(PixelColor.color("F0F4F8"));landingCanvas.fill(CGRect(x: 0,y: 0,width: landingCanvas.width,height: landingCanvas.height))
for (row,kind) in landingRows.enumerated() {
    let rowCanvas = pixelBitmap(landingTileW*landingSamples.count,landingTileH)
    rowCanvas.setFillColor(PixelColor.color("F0F4F8"));rowCanvas.fill(CGRect(x: 0,y: 0,width: rowCanvas.width,height: rowCanvas.height))
    for (col,sample) in landingSamples.enumerated() {
        let m = landingModel();m.chooseOutfit(landingOutfit(kind));m.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: 40,resetsAt: nil))
        let h: CGFloat = sample.0 ? 0 : (sample.1 < 0.125 ? 48 : 16)
        m.position = CGPoint(x: 500,y: m.floor+h)
        m.landing = LandingRun(kind: kind,started: 1000,height: 500,originX: 500,direction: 1,landedAt: sample.0 ? 1000 : nil)
        if sample.0 && sample.1 >= kind.settleDuration { m.landing = nil }
        m.actIndex = 0;m.actSince = 1000
        m.landingClock = 1000+sample.1
        m.landingLines = LandingLines()
        m.speech = m.landingLines.line(role: landingRole,kind: kind,landed: sample.0);m.speechUntil = 1003
        let v = PetView(model: m);v.anchor = CGPoint(x: 120,y: 40+h);v.time = 1000+sample.1
        let layer = pixelBitmap(landingTileW,landingTileH)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: layer,flipped: false)
        v.draw(v.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let pixels = layer.data!.assumingMemoryBound(to: UInt8.self)
        var nonbinary = 0
        for y in 0..<layer.height { for x in 0..<layer.width {
            let a = pixels[y*layer.bytesPerRow+x*4+3];if a != 0 && a != 255 { nonbinary += 1 }
        } }
        check(nonbinary == 0,"full landing PetView raster including speech has binary alpha")
        rowCanvas.draw(layer.makeImage()!,in: CGRect(x: col*landingTileW,y: 0,width: landingTileW,height: landingTileH))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: rowCanvas,flipped: false)
        let phase = sample.0 ? "landed" : sample.1 < 0.125 ? "falling" : "protected"
        ("\(kind.rawValue) · \(phase) \(sample.1)s" as NSString).draw(at: CGPoint(x: col*landingTileW+6,y: 340),withAttributes: [.font:NSFont.monospacedSystemFont(ofSize: 11,weight: .medium),.foregroundColor:NSColor.darkGray])
        NSGraphicsContext.restoreGraphicsState()
    }
    let image = rowCanvas.makeImage()!
    try NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:])!.write(to: landingTestRoot.appendingPathComponent("\(kind.rawValue).png"))
    landingCanvas.draw(image,in: CGRect(x: 0,y: (landingRows.count-1-row)*landingTileH,width: rowCanvas.width,height: rowCanvas.height))
}
let landingOutput = landingRoot.appendingPathComponent("landing-preview.png")
try NSBitmapImageRep(cgImage: landingCanvas.makeImage()!).representation(using: .png,properties: [:])!.write(to: landingOutput)
print("PASS: \(checks-landingCheckStart) landing assertions (\(landingRole.rawValue)); rendered \(landingOutput.path)")
