// Task 12: pure policy boundaries plus two real coordinators with temporary JSON transport.
let playCheckStart = checks
let playTestRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/checks/play-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: playTestRoot,withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: playTestRoot) }
func playPosition(_ x: CGFloat = 400,_ mood: String = "idle",_ now: Double = 1000) -> MeetingPosition {
    .init(x: x,y: 36,screen: "0,0,1440,900",facing: "right",mood: mood,detail: "",busy: false,ts: now,minX: 104,maxX: 1336,stageBack: 56,stageFront: 56,walkSpeed: 32)
}
func policy(_ c: MeetingPosition,_ d: MeetingPosition,_ prepare: (inout InteractionRules)->Void = { _ in }) -> InteractionRules {
    var r = InteractionRules();r.observe(c,d,now: 1000,choose: { _ in 0 });prepare(&r);return r
}
let playC = playPosition(),playD = playPosition(700)
for role in MeetingRole.allCases {
    for k in InteractionKind.allCases {
        var c = playC,d = playD
        var rules = policy(c,d)
        switch k {
        case .celebrate,.comfort: if role == .claude { c.mood = k == .comfort ? "error" : "done" } else { d.mood = k == .comfort ? "error" : "done" }
        case .cheer: if role == .claude { c.mood = "working" } else { d.mood = "thinking" };rules.observe(c,d,now: 940)
        case .give_battery: if role == .claude { c.quota5h = 19 } else { d.quota5h = 19 }
        case .fireworks: if role == .claude { c.quota5h = 20 } else { d.quota5h = 20 };rules.observe(c,d,now: 999);if role == .claude { c.quota5h = 50 } else { d.quota5h = 50 }
        case .soccer,.rps,.hide_seek: rules.idleTimer = 600
        case .nap: break
        }
        rules.observe(c,d,now: 1000)
        let idx: (Int)->Int = { count in count == 3 ? ([InteractionKind.soccer,.rps,.hide_seek].firstIndex(of: k) ?? 0) : 0 }
        let choice = rules.choose(c,d,now: 1000,hour: 12,inputIdle: k == .nap ? 600 : 0,index: idx)
        check(choice?.kind == k,"natural trigger \(k), role \(role)")
        for side in 0...1 { for obstruction in 0..<5 {
            var a = c,b = d,p = side == 0 ? a : b
            switch obstruction { case 0: p.dragging = true;case 1: p.grounded = false;case 2: p.trick = true;case 3: p.busy = true;default: p.ts -= 3.01 }
            if side == 0 { a = p } else { b = p }
            check(rules.choose(a,b,now: 1000,hour: 12,inputIdle: 600) == nil,"\(k) blocked on either pet \(obstruction)")
            check(rules.choose(a,b,now: 1000,hour: 12,inputIdle: 600,forced: k) == nil,"forced \(k) obeys readiness")
        } }
        var blocked = rules;blocked.lastAny = 940.01
        check(blocked.choose(c,d,now: 1000,hour: 12,inputIdle: 600) == nil,"all kinds global 60-second gap")
        check(blocked.choose(c,d,now: 1000,hour: 12,inputIdle: 600,forced: k)?.kind == k,"debug bypasses cooldown")
        blocked.lastAny = 940;check(blocked.choose(c,d,now: 1000,hour: 12,inputIdle: k == .nap ? 600 : 0,index: idx) != nil,"global gap inclusive at 60")
        if k.cooldown > 0 {
            blocked = rules;blocked.lastKind[k.rawValue] = 1000-k.cooldown+0.01
            check(blocked.choose(c,d,now: 1000,hour: 12,inputIdle: 0)?.kind != k,"per-kind cooldown \(k)")
            blocked.lastKind[k.rawValue] = 1000-k.cooldown
            check(blocked.choose(c,d,now: 1000,hour: 12,inputIdle: 0)?.kind == k,"per-kind cooldown boundary \(k)")
        }
    }
}
var low = playC;low.quota5h = 19
var episode = policy(low,playD)
let lowChoice = episode.choose(low,playD,now: 1000,hour: 12,inputIdle: 0)!
episode.started(lowChoice,now: 800,script: [])
check(episode.choose(low,playD,now: 1000,hour: 12,inputIdle: 0) == nil,"battery only once in low episode")
low.quota5h = 25;episode.observe(low,playD,now: 1000);low.quota5h = 19;episode.observe(low,playD,now: 1000)
check(episode.choose(low,playD,now: 1000,hour: 12,inputIdle: 0) == nil,"25 does not re-arm")
low.quota5h = 26;episode.observe(low,playD,now: 1000);low.quota5h = 19;episode.observe(low,playD,now: 1000)
check(episode.choose(low,playD,now: 1000,hour: 12,inputIdle: 0)?.kind == .give_battery,"above 25 re-arms")
var resetC = playC;resetC.reset5h = 1000;resetC.quota5h = 10
var resets = policy(resetC,playD)
check(resets.pending.filter { $0.kind == .fireworks }.count == 1,"reset time passing triggers fireworks")
resets.started(.init(kind: .fireworks,subject: .claude),now: 900,script: [])
resetC.quota5h = 100;resets.observe(resetC,playD,now: 1000)
check(!resets.pending.contains { $0.kind == .fireworks },"same reset quota jump is not celebrated twice")
resets.observe(resetC,playD,now: 1001)
check(!resets.pending.contains { $0.kind == .fireworks },"past reset is consumed")
for hour in [7,8,9] { check(policy(playC,playD).choose(playC,playD,now: 1000,hour: hour,inputIdle: 600) == nil,"nap excludes morning hour \(hour)") }
check(policy(playC,playD).choose(playC,playD,now: 1000,hour: 10,inputIdle: 599.99) == nil,"nap requires 600 seconds without input")
var timer = policy(playC,playD);timer.idleTimer = 300;timer.idleGoal = 300
timer.started(.init(kind: .soccer,subject: .claude),now: 900,script: [],index: { _ in 300 })
check(timer.idleTimer == 0 && timer.idleGoal == 600,"all self-play shares one freshly randomized timer")
var busyC = playC;busyC.mood = "working";timer.observe(busyC,playD,now: 1000)
check(timer.idleTimer == 0,"random timer only accumulates while both rest")
let playLibrary = InteractionLines.load(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/pet/play-lines.json"))
for k in InteractionKind.allCases {
    check(playLibrary[k.rawValue]?.count == 3,"read real mixed-schema library \(k)")
    var last: String?
    for _ in 0..<10 { let lines = InteractionLines.pick(k,pool: playLibrary[k.rawValue]!,last: last,index: { _ in 0 });let key = InteractionLines.key(lines);check(key != last,"no script repeat per kind");last = key }
    check(!InteractionLines.pick(k,pool: [],last: nil).isEmpty,"missing-file fallback")
}
for a in RPSHand.allCases { for b in RPSHand.allCases {
    let r = RPSRound(claude: a,codex: b)
    check((r.winner == nil) == (a == b),"RPS ties match icons")
    if let winner = r.winner { let winning = r.hand(winner),losing = r.hand(winner.other);check((winning == .rock && losing == .scissors) || (winning == .scissors && losing == .paper) || (winning == .paper && losing == .rock),"RPS winner follows shown hands") }
} }
func testPlayModel(_ x: CGFloat) -> PetModel {
    let m = PetModel(frame: CGRect(x: 0,y: 0,width: 1440,height: 900),lines: SpeechLines(url: playTestRoot.appendingPathComponent("no-lines")),now: 1000,preferences: MemoryDefaults())
    m.chooseSize(.medium);m.position = CGPoint(x: x,y: m.floor);m.quiet = true;return m
}
for kind in InteractionKind.allCases {
    let dir = playTestRoot.appendingPathComponent(kind.rawValue)
    let c = testPlayModel(480),d = testPlayModel(720)
    var clock = 2100000000.0,varIdle = 800.0
    let leader = MeetingCoordinator(role: .claude,directory: dir),follower = MeetingCoordinator(role: .codex,directory: dir)
    c.meeting = leader;d.meeting = follower
    leader.epochNow = { clock };follower.epochNow = { clock };leader.inputIdle = { varIdle };follower.inputIdle = { varIdle }
    leader.forcedInteraction = kind;follower.publishPosition(d)
    leader.update(c,dt: 0.125,uptime: 1000);follower.update(d,dt: 0.125,uptime: 1000)
    check(leader.active?.interactionKind == kind && leader.active == follower.active,"leader/follower agree for \(kind)")
    let plan = leader.active!
    check(plan.valid,"valid frozen \(kind) plan")
    let encoded = try JSONEncoder().encode(plan),decoded = try JSONDecoder().decode(MeetingPlan.self,from: encoded)
    check(decoded == plan,"complete plan survives JSON \(kind)")
    var reachedSleep = false
    let limit = kind == .nap ? plan.start+plan.actionAt+4 : plan.start+plan.end+1
    while clock < limit {
        clock += 0.125
        let uptime = 1000+clock-2100000000
        if kind == .nap,clock > plan.start+plan.actionAt+2 { varIdle = 0 }
        leader.update(c,dt: 0.125,uptime: uptime);follower.update(d,dt: 0.125,uptime: uptime)
        if kind != .fireworks && clock >= plan.start {
            check(abs(c.position.x-d.position.x)+0.01 >= abs(plan.claudeX-plan.codexX),"live seek / formation spacing \(kind)")
        }
        check(c.position.x == c.position.x.rounded() && d.position.x == d.position.x.rounded(),"whole-point live motion \(kind)")
        if kind == .nap,clock > plan.start+plan.actionAt+1,varIdle > 0 { reachedSleep = true;check(leader.active != nil && follower.active != nil,"nap persists until input") }
        if let active = leader.active,kind == .rps { let age = active.playAge(clock);if age >= 0 { let p = active.play!,n = min(p.rounds.count-1,Int(age/5));check(p.rounds[n] == follower.active?.play?.rounds[n],"same round and hands on both pets") } }
    }
    check(leader.active == nil && follower.active == nil,"\(kind) completes on both coordinators")
    if kind == .nap { check(reachedSleep,"forced nap reaches sleep before waking") }
    if kind == .hide_seek { check(c.position.x >= c.visibleFrame.minX+c.edgeInset && c.position.x <= c.visibleFrame.maxX-c.edgeInset && d.position.x >= d.visibleFrame.minX+d.edgeInset && d.position.x <= d.visibleFrame.maxX-d.edgeInset,"hider returns fully on screen") }
    // New instance, same saved history: per-kind policy state survives restart.
    let resumed = MeetingCoordinator(role: .claude,directory: dir)
    check(resumed.rules.lastKind[kind.rawValue] != nil,"\(kind) cooldown persisted")
    // Abort paths apply to every kind, without waiting through the animation again.
    leader.setPreview(plan: plan);follower.setPreview(plan: plan);c.dragging = true;leader.dragged(c)
    check(leader.active == nil,"drag abort \(kind)")
    follower.update(d,dt: 0,uptime: 1000);check(follower.active == nil,"remote drag abort \(kind)")
    c.dragging = false;leader.setPreview(plan: plan);clock += 4
    leader.update(c,dt: 0,uptime: 1000);check(leader.active == nil,"peer timeout abort \(kind)")
}
// Reset metadata may lead the eventual quota update by several minutes.
var delayedResetC = playC,delayedResetD = playD
delayedResetC.reset5h = 1000;delayedResetC.quota5h = 10
var delayedReset = policy(delayedResetC,delayedResetD)
delayedReset.started(.init(kind: .fireworks,subject: .claude),now: 1000,script: [])
delayedResetC.ts = 1120;delayedResetD.ts = 1120;delayedResetC.quota5h = 100
delayedReset.observe(delayedResetC,delayedResetD,now: 1120)
check(!delayedReset.pending.contains { $0.kind == .fireworks },"late quota fill is still the same reset")
var remoteD = playD;remoteD.screen = "1440,0,1440,900"
var remoteReset = policy(resetC,remoteD)
check(remoteReset.choose(resetC,remoteD,now: 1000,hour: 12,inputIdle: 0)?.kind == .fireworks,"fireworks works across displays without a seek walk")
check(remoteReset.choose(playC,remoteD,now: 1000,hour: 12,inputIdle: 0,forced: .soccer) == nil,"other interactions require a shared screen")
var threshold = playC;threshold.quota5h = 20
check(policy(threshold,playD).choose(threshold,playD,now: 1000,hour: 12,inputIdle: 0) == nil,"20 percent does not trigger a battery")
for stop in ["cheer", "nap-mood", "nap-input"] {
    let dir = playTestRoot.appendingPathComponent(stop),c = testPlayModel(480),d = testPlayModel(720)
    var clock = 2200000000.0,idle = 800.0
    let leader = MeetingCoordinator(role: .claude,directory: dir),follower = MeetingCoordinator(role: .codex,directory: dir)
    c.meeting = leader;d.meeting = follower;leader.epochNow = { clock };follower.epochNow = { clock };leader.inputIdle = { idle }
    try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
    let choice = InteractionChoice(kind: stop == "cheer" ? .cheer : .nap,subject: .claude)
    c.state = stop == "cheer" ? .working : .idle
    let plan = InteractionPlanner.make(choice,c: leader.snapshot(c,now: clock),d: follower.snapshot(d,now: clock),now: clock,script: [.init(who: .claude,text: "一起歇会")])
    try JSONEncoder().encode(plan).write(to: leader.planURL,options: .atomic)
    leader.setPreview(plan: plan);follower.setPreview(plan: plan)
    leader.publishPosition(c);follower.publishPosition(d)
    clock = plan.start+plan.actionAt+0.5
    leader.publishPosition(c);follower.publishPosition(d)
    if stop == "nap-input" { idle = 0 } else { c.state = .done }
    leader.update(c,dt: 0.125,uptime: 1000);follower.update(d,dt: 0.125,uptime: 1000)
    check(leader.active?.play?.releaseAt == clock && follower.active?.play?.releaseAt == clock,"shared early stop / wake plan \(stop)")
    clock += 1.125;leader.publishPosition(c);follower.publishPosition(d)
    leader.update(c,dt: 0.125,uptime: 1001);follower.update(d,dt: 0.125,uptime: 1001)
    check(leader.active == nil && follower.active == nil,"one-second wake/departure finishes \(stop)")
}
print("PASS: \(checks-playCheckStart) Task 12 policy, script, transport, wake and abort assertions (\(MeetingRole.local.rawValue))")
