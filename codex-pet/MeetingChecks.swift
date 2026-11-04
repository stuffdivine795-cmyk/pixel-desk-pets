// Appended to each app's real offscreen model/view checks. No GUI entry point is used.
let meetingCheckStart = checks
let meetingTestRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("meeting-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: meetingTestRoot,withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: meetingTestRoot) }
let meetingFrame = CGRect(x: 0,y: 0,width: 1440,height: 900)
func meetingModel(_ x: CGFloat) -> PetModel {
    let m = PetModel(frame: meetingFrame,lines: SpeechLines(url: meetingTestRoot.appendingPathComponent("no-lines.json")),now: 1000,preferences: MemoryDefaults())
    m.chooseSize(.medium);m.position = CGPoint(x: x,y: m.floor);m.quiet = true
    return m
}
var meetingTime = 2000000000.0
let meetingClaude = meetingModel(500),meetingCodex = meetingModel(600)
// The real input-idle clock would turn meetings into naps when the user is away.
MeetingCoordinator.defaultInputIdle = { 0 }
let meetingLeader = MeetingCoordinator(role: .claude,directory: meetingTestRoot)
let meetingFollower = MeetingCoordinator(role: .codex,directory: meetingTestRoot)
meetingLeader.epochNow = { meetingTime };meetingFollower.epochNow = { meetingTime }
meetingClaude.meeting = meetingLeader;meetingCodex.meeting = meetingFollower
var meetingC = meetingLeader.snapshot(meetingClaude,now: meetingTime)
var meetingD = meetingFollower.snapshot(meetingCodex,now: meetingTime)
check(meetingC.quota5h == nil,"unknown quota retained")
let meetingJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meetingC)) as! [String: Any]
check(meetingJSON["quota5h"] is NSNull,"unknown quota encoded explicitly as null")
check(MeetingRules.canMeet(meetingC,meetingD,now: meetingTime,last: meetingTime-180,forced: false),"grounded, same screen, close enough, cooldown elapsed")
for distance: CGFloat in [120,121,500] {
    var p = meetingD;p.x = meetingC.x+distance
    check(!MeetingRules.canMeet(meetingC,p,now: meetingTime,last: 0,forced: false),"distance boundary excludes \(distance)")
}
for scale: CGFloat in [0.75,1,1.25] {
    var c = meetingC,d = meetingD;c.scale = scale;d.scale = scale;d.x = c.x+119*scale
    check(MeetingRules.canMeet(c,d,now: meetingTime,last: 0,forced: false),"size-scaled detection")
    d.x = c.x+120*scale
    check(!MeetingRules.canMeet(c,d,now: meetingTime,last: 0,forced: false),"size-scaled strict boundary")
}
check(!MeetingRules.canMeet(meetingC,meetingD,now: meetingTime,last: meetingTime-179.99,forced: false),"three-minute cooldown")
check(MeetingRules.canMeet(meetingC,meetingD,now: meetingTime,last: meetingTime,forced: true),"manual request bypasses cooldown")
for mutation in 0..<6 {
    var p = meetingD
    switch mutation {
    case 0: p.ts -= 3.01
    case 1: p.screen = "another-screen"
    case 2: p.grounded = false
    case 3: p.dragging = true
    case 4: p.trick = true
    default: p.busy = true
    }
    check(!MeetingRules.canMeet(meetingC,p,now: meetingTime,last: 0,forced: true),"forced meeting still obeys freshness/readiness/screen \(mutation)")
}
var priorityC = meetingC,priorityD = meetingD
priorityC.mood = "working";priorityC.detail = "swiftc";priorityD.mood = "thinking"
func situation(_ hour: Int = 12,_ choice: Int = 0) -> String {
    MeetingRules.situation(priorityC,priorityD,now: meetingTime,hour: hour,choose: { _ in choice })
}
check(situation() == "both_busy","both busy")
priorityD.mood = "idle";check(situation() == "claude_busy","Claude busy")
priorityC.mood = "idle";priorityD.mood = "working";check(situation() == "codex_busy","Codex busy")
priorityD.mood = "idle";check(situation() == "both_idle","idle")
for hour in [23,0,5] { check(situation(hour) == "late_night","late night includes \(hour)") }
for hour in [6,22] { check(situation(hour) == "both_idle","late night excludes \(hour)") }
priorityC.doneAt = meetingTime-59.9;check(situation(23) == "after_done","recent done beats night")
priorityC.doneAt = meetingTime-60;check(situation(23) == "late_night","done expires at 60 seconds")
priorityD.doneAt = meetingTime-1;priorityC.quota5h = 19
check(situation(23) == "quota_low_claude","low quota beats recent done and night")
priorityD.quota5h = 5
check(situation(23,0) == "quota_low_claude" && situation(23,1) == "quota_low_codex","both low chooses either, without priority bias")
priorityC.quota5h = 20;check(situation() == "quota_low_codex","20 percent is not low")
priorityC.mood = "working";priorityD.quota5h = nil
check(MeetingRules.fill("{claude_quota}/{codex_quota}/{tool}",claude: priorityC,codex: priorityD) == "20%/?/swiftc","quota and busy tool placeholders")
priorityC.mood = "idle"
check(MeetingRules.fill("{tool}",claude: priorityC,codex: priorityD) == "代码","tool fallback")
check(MeetingRules.fallbacks.count == 8,"a built-in script for every situation")
let meetingScript = MeetingScript(lines: [.init(who: .claude,text: "一起散步吧"),.init(who: .codex,text: "水跟着你走")],action: "high_five")
// Read the user's real library without writing it; make sure all its situations/actions decode.
let meetingLibraryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/pet/meet-lines.json")
if let data = try? Data(contentsOf: meetingLibraryURL) {
    let library = try JSONDecoder().decode([String: [MeetingScript]].self,from: data)
    check(Set(library.keys).isSuperset(of: MeetingRules.fallbacks.keys),"real script library has all situations")
    check(library.values.flatMap { $0 }.allSatisfy { MeetingDrawing.actions.contains($0.action) },"real script library actions supported")
}
// The fourth choice is the only legal choice after three scripts have been used.
let repetitionPool = (0..<4).map { n in MeetingScript(lines: [.init(who: .claude,text: "script \(n)")],action: "wave") }
for _ in 0..<20 {
    check(MeetingRules.select(repetitionPool,history: Array(repetitionPool.prefix(3)).map(\.key),fallback: meetingScript).key == repetitionPool[3].key,"avoids the last three scripts")
}
check(MeetingRules.select([],history: [],fallback: meetingScript).key == meetingScript.key,"missing library uses fallback")
check(MeetingRules.select(Array(repetitionPool.prefix(2)),history: Array(repetitionPool.prefix(2)).map(\.key),fallback: meetingScript).key == repetitionPool[0].key,"small pool uses oldest available script")
var closeC = meetingC,closeD = meetingD;closeD.x = closeC.x+20
let closePlan = MeetingRules.plan(script: meetingScript,situation: "both_idle",c: closeC,d: closeD,now: meetingTime)
check(abs(closePlan.claudeX-closePlan.codexX) == MeetingRules.stageDistance(closeC,closeD,action: meetingScript.action),"overlapping pets stage from sprite extents plus two units")
check([closePlan.claudeX,closePlan.codexX].allSatisfy { $0 == $0.rounded() },"stage feet use whole points")
closeC.x = 144;closeD.x = 144;closeC.minX = 144;closeD.minX = 144
let edgePlan = MeetingRules.plan(script: meetingScript,situation: "both_idle",c: closeC,d: closeD,now: meetingTime)
check(edgePlan.claudeX >= 144 && edgePlan.codexX >= 144 && edgePlan.codexX-edgePlan.claudeX == MeetingRules.stageDistance(closeC,closeD,action: meetingScript.action),"formation shifts away from screen edge")
// Keep the integration schedule deterministic regardless of the real time-of-day.
let meetingFixtures = Dictionary(uniqueKeysWithValues: MeetingRules.fallbacks.keys.map { ($0,[meetingScript]) })
try JSONEncoder().encode(meetingFixtures).write(to: meetingTestRoot.appendingPathComponent("meet-lines.json"),options: .atomic)
func meetingAdvance(_ seconds: Double) {
    let frames = Int((seconds/0.125).rounded())
    for _ in 0..<frames {
        meetingTime += 0.125
        let up = 1000+meetingTime-2000000000
        meetingClaude.step(dt: 0.125,now: up);meetingCodex.step(dt: 0.125,now: up)
    }
}
meetingAdvance(1)
check(meetingLeader.active != nil && meetingFollower.active != nil,"leader and follower both accept one meeting")
let meetingPlan = meetingLeader.active!
check(meetingPlan == meetingFollower.active,"both processes agree on exact meet.json UUID, stage and timing")
let meetingDisk = try JSONDecoder().decode(MeetingPlan.self,from: Data(contentsOf: meetingLeader.planURL))
check(meetingDisk == meetingPlan && meetingDisk.valid,"atomic meet.json round trip")
for (offset,speaker) in [(0.0,MeetingRole.claude),(2.599,.claude),(2.6,.codex),(5.199,.codex)] {
    check(meetingPlan.line(at: meetingPlan.start+offset,for: speaker) != nil,"line is said by the right pet at \(offset)")
    check(meetingPlan.line(at: meetingPlan.start+offset,for: speaker.other) == nil,"other pet stays silent at \(offset)")
}
check(meetingPlan.line(at: meetingPlan.start-0.01,for: .claude) == nil,"no line before start")
check(meetingPlan.line(at: meetingPlan.start+5.2,for: .codex) == nil,"no line during action")
meetingAdvance(1)
let meetingBeforeMood = meetingClaude.speech
meetingClaude.transition(to: .working,now: 1002)
check(meetingClaude.state == .working && meetingClaude.speech == meetingBeforeMood,"mood face changes, normal speech suppressed")
meetingClaude.click(now: 1002);check(meetingClaude.trick == nil,"click cannot insert a trick into meeting")
let meetingWorkingView = PetView(model: meetingClaude);meetingWorkingView.time = 1002
check(meetingWorkingView.contextMenu().item(withTitle: MeetingRole.local == .claude ? "去找小水滴" : "去找小橘") != nil,"find-friend menu is wired")
check(meetingCodex.speech.isEmpty,"only active speaker has a speech bubble")
// Four scripts can put the action after 10 s; no process may drop it at that age.
let actionMidpoint = meetingPlan.start+meetingPlan.actionAt+1
meetingAdvance(max(0,actionMidpoint-meetingTime))
check(meetingLeader.active != nil && meetingFollower.active != nil,"both coordinators remain active at actionAt + 1 s")
check(meetingPlan.action(at: meetingTime) == meetingPlan.action,"action clock selects the ending action at its midpoint")
for pet in [meetingClaude,meetingCodex] {
    let view = PetView(model: pet)
    check(view.meetingSprite != nil,"both actual views render meeting action frames at +1 s")
}
meetingAdvance(3)
check(meetingLeader.active == nil && meetingFollower.active == nil,"both leave after the action")
check(meetingClaude.direction == -meetingPlan.direction(.claude) && meetingCodex.direction == -meetingPlan.direction(.codex),"both depart away from their partner")
meetingAdvance(5)
meetingClaude.position.x = 500;meetingCodex.position.x = 580
meetingAdvance(1)
check(meetingLeader.active == nil && meetingFollower.active == nil,"natural encounter respects stored cooldown")
// A request from the follower must reach the leader without the follower ever writing meet.json.
let meetingOldData = try Data(contentsOf: meetingLeader.planURL)
meetingFollower.findFriend(meetingCodex)
let meetingUnchangedData = try Data(contentsOf: meetingLeader.planURL)
check(meetingUnchangedData == meetingOldData,"follower menu only publishes a request")
meetingAdvance(1.5)
check(meetingLeader.active != nil && meetingLeader.active == meetingFollower.active,"follower's manual request bypasses leader cooldown")
check(meetingLeader.active?.id != meetingPlan.id,"new meeting UUID")
meetingClaude.dragging = true;meetingLeader.dragged(meetingClaude)
check(meetingLeader.active == nil,"local drag aborts immediately")
meetingAdvance(0.75)
check(meetingFollower.active == nil,"remote drag abort propagates by the next poll")
meetingClaude.dragging = false
meetingAdvance(5)
meetingClaude.position.x = 500;meetingCodex.position.x = 580
meetingLeader.findFriend(meetingClaude);meetingAdvance(1.5)
check(meetingLeader.active != nil && meetingFollower.active != nil,"leader menu can start another meeting")
// Simulate a crash: stop all follower ticks and leave its last file in place.
for _ in 0..<28 { meetingTime += 0.125;meetingClaude.step(dt: 0.125,now: 1020+meetingTime-2000000000) }
check(meetingLeader.active == nil,"crashed peer times out after three seconds")
// A delayed follower can still display the remaining action of a four-line meeting.
let lateDir = meetingTestRoot.appendingPathComponent("late-action")
try FileManager.default.createDirectory(at: lateDir,withIntermediateDirectories: true)
var latePlan = meetingPlan
latePlan.id = UUID().uuidString;latePlan.start = meetingTime-11.4
latePlan.lines = (0..<4).map { .init(who: $0%2 == 0 ? .claude : .codex,text: "late",at: Double($0)*2.6) }
latePlan.actionAt = 10.4;latePlan.end = 12.4
let latePet = meetingModel(600),lateFollower = MeetingCoordinator(role: .codex,directory: lateDir)
latePet.meeting = lateFollower;lateFollower.epochNow = { meetingTime }
var latePeer = meetingC;latePeer.ts = meetingTime;latePeer.busy = true;latePeer.meetingID = latePlan.id
try JSONEncoder().encode(latePlan).write(to: lateFollower.planURL)
try JSONEncoder().encode(latePeer).write(to: lateFollower.peerURL)
lateFollower.update(latePet,dt: 0,uptime: 1000)
check(lateFollower.active?.id == latePlan.id,"fresh matching follower accepts actionAt + 1 s after ten seconds")
check(latePlan.action(at: meetingTime) == latePlan.action,"four-line ending action survives the old age cutoff")

// Replays, stale plans and follower-only startup cannot create a meeting.
meetingFollower.shutdown();meetingLeader.shutdown()
let isolated = meetingTestRoot.appendingPathComponent("isolated")
try FileManager.default.createDirectory(at: isolated,withIntermediateDirectories: true)
var stalePlan = meetingPlan;stalePlan.start = meetingTime-11
try JSONEncoder().encode(stalePlan).write(to: isolated.appendingPathComponent("meet.json"))
let isolatedModel = meetingModel(600),isolatedFollower = MeetingCoordinator(role: .codex,directory: isolated)
isolatedFollower.epochNow = { meetingTime };isolatedModel.meeting = isolatedFollower
isolatedModel.step(dt: 0.125,now: 1000)
check(isolatedFollower.active == nil,"follower cannot meet without live leader")
var isolatedPeer = meetingC;isolatedPeer.ts = meetingTime;isolatedPeer.busy = true;isolatedPeer.meetingID = stalePlan.id
try JSONEncoder().encode(isolatedPeer).write(to: isolatedFollower.peerURL)
meetingTime += 0.5;isolatedFollower.update(isolatedModel,dt: 0,uptime: 1001)
check(isolatedFollower.active == nil,"stale start is rejected even with a fresh matching leader")
var replayPlan = meetingPlan;replayPlan.start = meetingTime+0.6
try JSONEncoder().encode(replayPlan).write(to: meetingFollower.planURL)
isolatedPeer.meetingID = replayPlan.id;isolatedPeer.ts = meetingTime
try JSONEncoder().encode(isolatedPeer).write(to: meetingFollower.peerURL)
let replayModel = meetingModel(600),replayFollower = MeetingCoordinator(role: .codex,directory: meetingTestRoot)
replayFollower.epochNow = { meetingTime };replayModel.meeting = replayFollower
replayFollower.update(replayModel,dt: 0,uptime: 1002)
check(replayFollower.active == nil,"already-played UUID is not replayed with live matching leader")

check(meetingFollower.history.played.contains(meetingPlan.id),"played IDs retained")
let resumed = MeetingCoordinator(role: .codex,directory: meetingTestRoot)
check(resumed.history.played.contains(meetingPlan.id),"played IDs survive restart")
// Idle heartbeat: unchanged half-second polls do not replace the file, but it never goes stale.
let heartDir = meetingTestRoot.appendingPathComponent("heartbeat"),heartModel = meetingModel(500)
let heart = MeetingCoordinator(role: .claude,directory: heartDir);heart.epochNow = { meetingTime };heartModel.meeting = heart
heart.update(heartModel,dt: 0,uptime: 1000)
let heartBytes = try Data(contentsOf: heart.ownURL)
meetingTime += 0.5;heart.update(heartModel,dt: 0,uptime: 1000.5)
let heartUnchangedBytes = try Data(contentsOf: heart.ownURL)
check(heartUnchangedBytes == heartBytes,"unchanged half-second poll skips writing")
meetingTime += 0.5;heart.update(heartModel,dt: 0,uptime: 1001)
let heartPosition = try JSONDecoder().decode(MeetingPosition.self,from: Data(contentsOf: heart.ownURL))
check(heartPosition.ts == meetingTime && heartPosition.fresh(meetingTime),"stationary pet refreshes heartbeat")
heart.shutdown();check(!FileManager.default.fileExists(atPath: heart.ownURL.path),"quit removes own position")

// Sweep every action, every mood, every size and both display densities using the actual PetView.sprite.
for density: CGFloat in [1,2] { for size in PetSize.allCases { for mood in PetState.allCases {
    let m = meetingModel(500);m.chooseSize(size);m.state = mood
    let coordinator = MeetingCoordinator(directory: meetingTestRoot.appendingPathComponent("render"))
    var renderTime = 3000000000.0;coordinator.epochNow = { renderTime };m.meeting = coordinator
    let v = PetView(model: m);v.anchor = CGPoint(x: 220,y: 40)
    for action in MeetingDrawing.actions {
        var c = meetingC,d = meetingD;c.scale = size.uiCell/8;d.scale = c.scale
        let plan = MeetingRules.plan(script: .init(lines: meetingScript.lines,action: action),situation: "both_idle",c: c,d: d,now: renderTime)
        // Test-only injection still exercises the same production renderer and complete plan.
        coordinator.setPreview(plan: plan)
        for frame in 0...64 {
            renderTime = plan.start+plan.actionAt+Double(frame)/32
            v.time = 1000+Double(frame)/32
            let base = v.sprite
            for p in base {
                check(p.color.alpha == 1,"meeting pixels opaque")
                verifyRect(p.rect,density,"meeting action")
            }
            check(v.bounds.contains(base.filter(\.interactive).reduce(CGRect.null) { $0.union($1.rect) }),"action body fits actual view")
        }
    }
} } }

// Render this app's half of each preview tile using its actual native PetView.
let meetingWorkspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let meetingLayers = meetingWorkspace.appendingPathComponent(".build/checks/meeting-layers")
try FileManager.default.createDirectory(at: meetingLayers,withIntermediateDirectories: true)
let meetingSamples = [0.125,0.375,0.75,0.875,1.0,1.75]
var meetingTiles: [(String,Double)] = [("conversation",0.4),("conversation",3.0)]
for action in MeetingDrawing.actions { for t in meetingSamples { meetingTiles.append((action,t)) } }
for (i,tile) in meetingTiles.enumerated() {
    let m = meetingModel(MeetingRole.local == .claude ? 122 : 222)
    #if DESK_PET
    m.chooseOutfit(.witch)
    #endif
    let coordinator = MeetingCoordinator(directory: meetingTestRoot.appendingPathComponent("preview"))
    let c = MeetingPosition(x: 122,y: 32,screen: "preview",facing: "right",mood: "idle",detail: "",busy: false,ts: 1000)
    let d = MeetingPosition(x: 222,y: 32,screen: "preview",facing: "left",mood: "idle",detail: "",busy: false,ts: 1000)
    let plan = MeetingRules.plan(script: .init(lines: meetingScript.lines,action: tile.0 == "conversation" ? "wave" : tile.0),situation: "both_idle",c: c,d: d,now: 1000)
    let t = plan.start+(tile.0 == "conversation" ? tile.1 : plan.actionAt+tile.1)
    coordinator.epochNow = { t };coordinator.setPreview(plan: plan);m.meeting = coordinator
    m.direction = plan.direction(.local)
    m.position.x = plan.x(.local)
    m.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: 40,resetsAt: nil))
    let v = PetView(model: m);v.anchor = CGPoint(x: m.position.x,y: 32);v.time = 1000
    m.speech = plan.line(at: t,for: .local)?.text ?? "";m.speechUntil = 1001
    let context = pixelBitmap(688,460);context.scaleBy(x: 2,y: 2)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: false)
    v.draw(v.bounds)
    NSGraphicsContext.restoreGraphicsState()
    try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png,properties: [:])!
        .write(to: meetingLayers.appendingPathComponent("\(MeetingRole.local.rawValue)-\(i).png"))
}
// Each check script is independently usable. Whichever finishes second composes the two fresh native layers.
let meetingSibling = meetingWorkspace.deletingLastPathComponent().appendingPathComponent(MeetingRole.local == .claude ? "codex-pet" : "desk-pet")
let meetingPeerLayers = meetingSibling.appendingPathComponent(".build/checks/meeting-layers")
if FileManager.default.fileExists(atPath: meetingPeerLayers.appendingPathComponent("\(MeetingRole.local.other.rawValue)-49.png").path) {
    let width = 2064,height = 2138
    let canvas = pixelBitmap(width*2,height*2);canvas.scaleBy(x: 2,y: 2);PixelDrawing.crisp(canvas)
    canvas.setFillColor(PixelColor.color("EAF0F4"));canvas.fill(CGRect(x: 0,y: 0,width: width,height: height))
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas,flipped: false)
    for (i,tile) in meetingTiles.enumerated() {
        let row = i < 2 ? 0 : 1+(i-2)/6,col = i < 2 ? i : (i-2)%6
        let origin = CGPoint(x: CGFloat(col*344),y: CGFloat(height-32-(row+1)*234))
        canvas.setFillColor(PixelColor.color("C7D0D9"));canvas.fill(CGRect(x: origin.x+8,y: origin.y+31,width: 328,height: 1))
        canvas.interpolationQuality = .none
        for role in MeetingRole.allCases {
            let folder = role == .local ? meetingLayers : meetingPeerLayers
            let rep = NSBitmapImageRep(data: try Data(contentsOf: folder.appendingPathComponent("\(role.rawValue)-\(i).png")))!
            canvas.draw(rep.cgImage!,in: CGRect(x: origin.x,y: origin.y,width: 344,height: 230))
        }
        let label = tile.0+String(format: "  %.3f s",tile.1)
        (label as NSString).draw(at: CGPoint(x: origin.x+12,y: origin.y+211),withAttributes: [
            .font:NSFont.monospacedSystemFont(ofSize: 13,weight: .medium),.foregroundColor:NSColor.darkGray])
    }
    ("中 · shared ground · native pixel sprites & bubbles · conversation + 8 actions / 6 samples each" as NSString)
        .draw(at: CGPoint(x: 16,y: height-24),withAttributes: [.font:NSFont.monospacedSystemFont(ofSize: 15,weight: .medium),.foregroundColor:NSColor.darkGray])
    NSGraphicsContext.restoreGraphicsState()
    let output = meetingWorkspace.deletingLastPathComponent().appendingPathComponent("desk-pet/meet-preview.png")
    try NSBitmapImageRep(cgImage: canvas.makeImage()!).representation(using: .png,properties: [:])!.write(to: output)
    print("Rendered: \(output.path)")
}
print("PASS: \(checks-meetingCheckStart) meeting assertions (\(MeetingRole.local.rawValue)); protocol, scripts, timing, aborts, all action frames")
