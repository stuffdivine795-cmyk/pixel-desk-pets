import AppKit

// One protocol/clock/animation implementation for both apps. DeskPet is the only writer of meet.json.
enum MeetingRole: String, Codable, CaseIterable {
    case claude, codex
    var other: Self { self == .claude ? .codex : .claude }
    static var local: Self {
        #if DESK_PET
        return .claude
        #else
        return .codex
        #endif
    }
}

struct MeetingPosition: Codable, Equatable {
    var x: CGFloat, y: CGFloat
    var screen: String
    var facing: String
    var mood: String
    var detail: String
    var quota5h: Int?
    var busy: Bool
    var ts: Double
    // Readiness cannot be inferred from the feet alone (a trick may only change the drawing).
    var grounded: Bool = true
    var dragging: Bool = false
    var trick: Bool = false
    var scale: CGFloat = 1
    var doneAt: Double? = nil
    var seek: String? = nil
    var meetingID: String? = nil
    var cancelled: String? = nil
    var minX: CGFloat? = nil
    var maxX: CGFloat? = nil
    // Actual neutral meeting sprite extents, including arms and the current outfit.
    var stageBack: CGFloat? = nil
    var stageFront: CGFloat? = nil
    var walkSpeed: CGFloat? = nil
    var quotaPlate: QuotaBattery.Plate? = nil
    var reset5h: Double? = nil
    var stageTop: CGFloat? = nil
    static func screenID(_ frame: CGRect) -> String {
        [frame.minX,frame.minY,frame.width,frame.height].map { String(Int($0.rounded())) }.joined(separator: ",")
    }
    func fresh(_ now: Double) -> Bool { ts.isFinite && now-ts >= -1 && now-ts <= 3 }
    var ready: Bool { grounded && !dragging && !trick && !busy }
    var working: Bool { mood == "working" || mood == "thinking" }
    // Explicit null for unknown quota, as specified by the interchange format.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x,forKey: .x);try c.encode(y,forKey: .y);try c.encode(screen,forKey: .screen)
        try c.encode(facing,forKey: .facing);try c.encode(mood,forKey: .mood);try c.encode(detail,forKey: .detail)
        if let quota5h = quota5h { try c.encode(quota5h,forKey: .quota5h) } else { try c.encodeNil(forKey: .quota5h) }
        try c.encode(busy,forKey: .busy);try c.encode(ts,forKey: .ts);try c.encode(grounded,forKey: .grounded)
        try c.encode(dragging,forKey: .dragging);try c.encode(trick,forKey: .trick);try c.encode(scale,forKey: .scale)
        try c.encodeIfPresent(doneAt,forKey: .doneAt);try c.encodeIfPresent(seek,forKey: .seek)
        try c.encodeIfPresent(meetingID,forKey: .meetingID);try c.encodeIfPresent(cancelled,forKey: .cancelled)
        try c.encodeIfPresent(minX,forKey: .minX);try c.encodeIfPresent(maxX,forKey: .maxX)
        try c.encodeIfPresent(stageBack,forKey: .stageBack);try c.encodeIfPresent(stageFront,forKey: .stageFront)
        try c.encodeIfPresent(walkSpeed,forKey: .walkSpeed)
        try c.encodeIfPresent(quotaPlate,forKey: .quotaPlate)
        try c.encodeIfPresent(reset5h,forKey: .reset5h)
        try c.encodeIfPresent(stageTop,forKey: .stageTop)
    }
}

struct MeetingLine: Codable, Equatable {
    var who: MeetingRole
    var text: String
    var at: Double = 0
    enum CodingKeys: String, CodingKey { case who, text, at }
    init(who: MeetingRole,text: String,at: Double = 0) { self.who = who;self.text = text;self.at = at }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        who = try c.decode(MeetingRole.self,forKey: .who);text = try c.decode(String.self,forKey: .text)
        at = try c.decodeIfPresent(Double.self,forKey: .at) ?? 0
    }
}
struct MeetingScript: Codable { var lines: [MeetingLine];var action: String
    var key: String { action + "|" + lines.map { $0.who.rawValue+":"+$0.text }.joined(separator: "|") }
}
struct MeetingPlan: Codable, Equatable {
    var id: String
    var start: Double
    var situation: String
    var lines: [MeetingLine]
    var action: String
    var actionAt: Double
    var end: Double
    // Frozen stage coordinates prevent two independently polled processes chasing each other's positions.
    var claudeX: CGFloat, codexX: CGFloat
    var claudeY: CGFloat, codexY: CGFloat
    var screen: String
    var scale: CGFloat
    var claudeFront: CGFloat? = nil
    var codexFront: CGFloat? = nil
    var kind: String? = "meet"
    var play: InteractionPlan? = nil
    var contactX: CGFloat {
        let sign = direction(.claude)
        return ((claudeX+sign*(claudeFront ?? 56*scale))+(codexX-sign*(codexFront ?? 52*scale)))/2
    }
    func action(at now: Double) -> String? {
        return now >= start+actionAt && now < start+end ? action : nil
    }
    func x(_ role: MeetingRole) -> CGFloat { role == .claude ? claudeX : codexX }
    func y(_ role: MeetingRole) -> CGFloat { role == .claude ? claudeY : codexY }
    func direction(_ role: MeetingRole) -> CGFloat { x(role.other) >= x(role) ? 1 : -1 }
    func line(at now: Double,for role: MeetingRole) -> MeetingLine? {
        if isPlay {
            guard now >= start,now < start+end,let line = lines.last(where: { start+$0.at <= now }),now < start+line.at+2.6,line.who == role else { return nil };return line
        }
        guard now >= start, now < start+actionAt,
              let line = lines.last(where: { start+$0.at <= now }), now < start+line.at+2.6, line.who == role else { return nil }
        return line
    }
    var valid: Bool {
        if isPlay {
            return UUID(uuidString: id) != nil && start.isFinite && actionAt.isFinite && end.isFinite &&
                actionAt >= 0 && end > actionAt && end <= 315360010 && play!.valid &&
                (interactionKind != .rps || !play!.rounds.isEmpty) &&
                !lines.isEmpty && lines.count <= 20 && lines.allSatisfy { $0.at.isFinite && $0.at >= 0 && $0.at < end && !$0.text.isEmpty && $0.text.count <= 84 } &&
                [claudeX,codexX,claudeY,codexY,scale].allSatisfy(\.isFinite) && scale > 0 && scale <= 2
        }
        guard kind == nil || kind == "meet" else { return false }
        return UUID(uuidString: id) != nil && start.isFinite && actionAt.isFinite && end.isFinite &&
        MeetingDrawing.actions.contains(action) && !lines.isEmpty && lines.count <= 20 &&
        actionAt == Double(lines.count)*2.6 && abs(end-actionAt-2) < 0.001 &&
        lines.enumerated().allSatisfy { abs($0.element.at-Double($0.offset)*2.6) < 0.001 } &&
        [claudeX,codexX,claudeY,codexY,scale].allSatisfy(\.isFinite) && scale > 0 && scale <= 2
    }
}

enum MeetingRules {
    static func canMeet(_ a: MeetingPosition,_ b: MeetingPosition,now: Double,last: Double,forced: Bool) -> Bool {
        a.fresh(now) && b.fresh(now) && a.ready && b.ready && a.screen == b.screen &&
        abs(a.x-b.x) < 120*max(a.scale,b.scale) && (forced || now-last >= 180)
    }
    static func situation(_ c: MeetingPosition,_ d: MeetingPosition,now: Double,hour: Int,
                          choose: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String {
        var low: [String] = []
        if let q = c.quota5h,q < 20 { low.append("quota_low_claude") }
        if let q = d.quota5h,q < 20 { low.append("quota_low_codex") }
        if !low.isEmpty { return low[choose(low.count)] }
        if [c,d].contains(where: { p in p.doneAt.map { now-$0 >= 0 && now-$0 < 60 } ?? false }) { return "after_done" }
        if hour >= 23 || hour < 6 { return "late_night" }
        if c.working && d.working { return "both_busy" }
        if c.working { return "claude_busy" }
        if d.working { return "codex_busy" }
        return "both_idle"
    }
    static func fill(_ text: String,claude: MeetingPosition,codex: MeetingPosition) -> String {
        let tool = [claude,codex].first(where: { $0.working && !$0.detail.isEmpty })?.detail ?? "代码"
        return text.replacingOccurrences(of: "{claude_quota}",with: claude.quota5h.map { "\($0)%" } ?? "?")
            .replacingOccurrences(of: "{codex_quota}",with: codex.quota5h.map { "\($0)%" } ?? "?")
            .replacingOccurrences(of: "{tool}",with: tool)
    }
    static let fallbacks: [String: MeetingScript] = [
        "both_idle": .init(lines: [.init(who: .claude,text: "一起散步吧"),.init(who: .codex,text: "水跟着你走")],action: "wave"),
        "claude_busy": .init(lines: [.init(who: .codex,text: "{tool}辛苦啦"),.init(who: .claude,text: "击个掌加油")],action: "high_five"),
        "codex_busy": .init(lines: [.init(who: .claude,text: "{tool}快好了吗"),.init(who: .codex,text: "再等最后一滴")],action: "fist_bump"),
        "both_busy": .init(lines: [.init(who: .claude,text: "一起加油"),.init(who: .codex,text: "稳稳收工")],action: "fist_bump"),
        "quota_low_claude": .init(lines: [.init(who: .claude,text: "还剩{claude_quota}"),.init(who: .codex,text: "我陪你省着用")],action: "gift_back"),
        "quota_low_codex": .init(lines: [.init(who: .codex,text: "还剩{codex_quota}"),.init(who: .claude,text: "小橘陪着你")],action: "gift"),
        "after_done": .init(lines: [.init(who: .claude,text: "任务完成啦"),.init(who: .codex,text: "一起庆祝吧")],action: "jump_together"),
        "late_night": .init(lines: [.init(who: .claude,text: "夜深慢慢走"),.init(who: .codex,text: "我陪你靠岸")],action: "hug")]
    static func select(_ pool: [MeetingScript],history: [String],fallback: MeetingScript) -> MeetingScript {
        let choices = pool.filter { !history.contains($0.key) }
        return choices.randomElement() ?? pool.min(by: {
            (history.firstIndex(of: $0.key) ?? -1) < (history.firstIndex(of: $1.key) ?? -1)
        }) ?? fallback
    }
    static func front(_ p: MeetingPosition,role: MeetingRole,action: String = "") -> CGFloat {
        let value = p.stageFront ?? (role == .claude ? 56 : 52)*p.scale
        return action == "spin" ? max(value,p.stageBack ?? value) : value
    }
    static func stageDistance(_ c: MeetingPosition,_ d: MeetingPosition,action: String = "") -> CGFloat {
        // Two half-cell units, one from each pet (also works for mixed sizes).
        ceil(front(c,role: .claude,action: action)+front(d,role: .codex,action: action)+4*c.scale+4*d.scale)
    }
    static func plan(script: MeetingScript,situation: String,c: MeetingPosition,d: MeetingPosition,now: Double) -> MeetingPlan {
        let scale = max(c.scale,d.scale), mid = ((c.x+d.x)/2).rounded()
        let distance = stageDistance(c,d,action: script.action), sign: CGFloat = c.x <= d.x ? 1 : -1
        var cx = (mid-sign*distance/2).rounded(),dx = (mid+sign*distance/2).rounded()
        let low = max((c.minX ?? cx)-cx,(d.minX ?? dx)-dx)
        let high = min((c.maxX ?? cx)-cx,(d.maxX ?? dx)-dx)
        let shift = low <= high ? min(max(0,low),high).rounded() : 0
        cx += shift;dx += shift
        // Window placement also snaps feet. Choose stage feet on BOTH pets' real grids,
        // otherwise two independent rounding errors can consume the visible gap.
        let cu = max(1,(4*c.scale).rounded()),du = max(1,(4*d.scale).rounded())
        var best: (CGFloat,CGFloat,CGFloat)?
        for offset in -16...16 {
            let candidateC = (cx/cu).rounded()*cu+CGFloat(offset)*cu
            let candidateD = sign > 0 ? ceil((candidateC+distance)/du)*du : floor((candidateC-distance)/du)*du
            guard candidateC >= (c.minX ?? -.infinity),candidateC <= (c.maxX ?? .infinity),
                  candidateD >= (d.minX ?? -.infinity),candidateD <= (d.maxX ?? .infinity) else { continue }
            let score = (abs(candidateD-candidateC)-distance)*1000+abs((candidateC+candidateD)-(cx+dx))
            if best == nil || score < best!.2 { best = (candidateC,candidateD,score) }
        }
        if let best = best { cx = best.0;dx = best.1 }
        let staging = max(abs(cx-c.x)/max(1,c.walkSpeed ?? 33*c.scale),
                          abs(dx-d.x)/max(1,d.walkSpeed ?? 33*d.scale))
        return MeetingPlan(id: UUID().uuidString,start: now+staging+0.6,situation: situation,
            lines: script.lines.enumerated().map { .init(who: $0.element.who,
                text: fill($0.element.text,claude: c,codex: d),at: Double($0.offset)*2.6) },
            action: script.action,actionAt: Double(script.lines.count)*2.6,end: Double(script.lines.count)*2.6+2,
            claudeX: cx,codexX: dx,
            claudeY: c.y,codexY: d.y,screen: c.screen,scale: scale,
            claudeFront: front(c,role: .claude,action: script.action),codexFront: front(d,role: .codex,action: script.action))
    }
}

final class MeetingCoordinator {
    struct History: Codable { var played: [String] = [];var scripts: [String] = [];var last: Double = -1e10 }
    let role: MeetingRole
    let directory: URL
    private(set) var active: MeetingPlan?
    private(set) var peer: MeetingPosition?
    private(set) var history = History()
    private(set) var rules = InteractionRules()
    // Checks replace the default so the user's real idle time can't start a nap mid-test.
    static var defaultInputIdle: () -> Double = { CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType: CGEventType(rawValue: UInt32.max)!) }
    var inputIdle: () -> Double = MeetingCoordinator.defaultInputIdle
    var forcedInteraction: InteractionKind?
    private var nextDebugPoll = -Double.infinity
    private var returnX: CGFloat?
    private var returnPlan: MeetingPlan?
    private(set) var seek: String?
    private(set) var lastError: String?
    private var cancelled: String?
    private var nextPoll = -Double.infinity
    private var lastWrite = -Double.infinity
    private var lastPosition: MeetingPosition?
    private var lastDone: Double?
    private var previousMood = ""
    private var moveRemainder: Double = 0
    private var departUntil = -Double.infinity
    private var departDirection: CGFloat = 1
    private var consumedPeerSeek: String?
    private(set) var isWalking = false
    var suppressesBubbles: Bool { active != nil || returnX != nil }
    var controlsMotion: Bool { active != nil || seek != nil || departUntil > epochNow() || returnX != nil }
    var epochNow: () -> Double = { Date().timeIntervalSince1970 }
    var ownURL: URL { directory.appendingPathComponent("pos-\(role.rawValue).json") }
    var peerURL: URL { directory.appendingPathComponent("pos-\(role.other.rawValue).json") }
    var planURL: URL { directory.appendingPathComponent("meet.json") }
    private var rulesURL: URL { directory.appendingPathComponent("play-local-\(role.rawValue).json") }
    private var historyURL: URL { directory.appendingPathComponent("meet-local-\(role.rawValue).json") }
    init(role: MeetingRole = .local,directory: URL) {
        self.role = role;self.directory = directory
        if let h: History = read(historyURL) { history = h }
        if let r: InteractionRules = read(rulesURL) { rules = r;rules.lastObservation = nil }
        if let plan: MeetingPlan = read(planURL),plan.valid { history.last = max(history.last,plan.start) }
    }
    private func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url),data.count < 262144 else { return nil }
        return try? JSONDecoder().decode(T.self,from: data)
    }
    @discardableResult private func write<T: Encodable>(_ value: T,to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: url,options: .atomic);lastError = nil;return true
        } catch { lastError = error.localizedDescription;return false }
    }
    func snapshot(_ model: PetModel,now: Double) -> MeetingPosition {
        let f = model.visibleFrame
        let screen = MeetingPosition.screenID(f)
        let grid = PixelGrid(cell: model.size.uiCell)
        let extents = model.meetingExtents
        return MeetingPosition(x: grid.snap(model.position.x),y: grid.snap(model.position.y),screen: screen,
            facing: model.direction < 0 ? "left" : "right",mood: model.state.rawValue,detail: model.detail,
            quota5h: model.quota?.fiveHour?.remaining(at: Date(timeIntervalSince1970: now)),busy: active != nil || returnX != nil || now < departUntil,ts: now,
            grounded: model.grounded,dragging: model.dragging,trick: model.trick != nil || model.landing != nil,scale: model.size.uiCell/8,
            doneAt: lastDone,seek: seek,meetingID: active?.id,cancelled: cancelled,
            minX: f.minX+model.edgeInset,maxX: f.maxX-model.edgeInset,
            stageBack: extents.back,stageFront: extents.front,
            walkSpeed: (model.state == .working ? 76 : model.state == .error ? 50 : 25)*model.size.scale,
            quotaPlate: model.quotaPlacement(at: Date(timeIntervalSince1970: now)),
            reset5h: model.quota?.fiveHour?.resetsAt?.timeIntervalSince1970,stageTop: extents.top)
    }
    private func publish(_ model: PetModel,now: Double,force: Bool = false) {
        let position = snapshot(model,now: now)
        var comparison = position;comparison.ts = lastPosition?.ts ?? now
        // Skip unchanged polls, but refresh the timestamp once a second: a stationary pet must stay alive.
        if force || comparison != lastPosition || now-lastWrite >= 1 {
            if write(position,to: ownURL) { lastPosition = position;lastWrite = now }
        }
    }
    // Called after model motion, including early returns for meeting/landing motion.
    // Unchanged frames still avoid disk writes through publish's comparison above.
    func publishPosition(_ model: PetModel) { publish(model,now: epochNow()) }
    func findFriend(_ model: PetModel) {
        let now = epochNow()
        guard let p: MeetingPosition = read(peerURL),p.fresh(now) else { return }
        peer = p;seek = UUID().uuidString;departUntil = -Double.infinity
        publish(model,now: now,force: true)
    }
    private func accept(_ plan: MeetingPlan,model: PetModel,now: Double) {
        active = plan;returnX = nil;returnPlan = nil;seek = nil;departUntil = -Double.infinity;moveRemainder = 0
        rules.lastAny = now;write(rules,to: rulesURL)
        history.last = plan.start;history.played = Array((history.played+[plan.id]).suffix(16))
        write(history,to: historyURL)
        model.trick = nil;model.velocityY = 0;model.speech = "";model.speechUntil = 0
        model.direction = plan.direction(role)
        publish(model,now: now,force: true)
    }
    private func finish(_ model: PetModel,now: Double,aborted: Bool = false) {
        guard let plan = active else { return }
        active = nil;cancelled = plan.id;seek = nil
        departDirection = -plan.direction(role);departUntil = now+4;moveRemainder = 0;isWalking = true
        model.speech = "";model.speechUntil = 0;model.direction = departDirection
        model.idleSince = ProcessInfo.processInfo.systemUptime
        rules.lastAny = now;write(rules,to: rulesURL)
        if let p = plan.play {
            returnPlan = aborted ? nil : plan
            departUntil = -Double.infinity
            // Returning to the original side cannot cross the partner's frozen formation.
            let origin = p.origin(role),other = peer?.x ?? plan.x(role.other)
            let distance = abs(plan.claudeX-plan.codexX)
            let side: CGFloat = model.position.x <= other ? -1 : 1
            returnX = aborted ? nil : (side < 0 ? min(origin,other-distance) : max(origin,other+distance))
            model.constrainX()
        }
        publish(model,now: now,force: true)
    }
    func dragged(_ model: PetModel) {
        let now = epochNow()
        finish(model,now: now,aborted: true);returnX = nil;seek = nil;departUntil = -Double.infinity
        history.last = now;write(history,to: historyURL)
        publish(model,now: now,force: true)
    }
    #if MEETING_CHECKS
    func setPreview(plan: MeetingPlan) { active = plan }
    func setPreviewPeer(_ position: MeetingPosition?) { peer = position }
    #endif
    func shutdown() { try? FileManager.default.removeItem(at: ownURL) }
    @discardableResult func update(_ model: PetModel,dt: Double,uptime: Double) -> Bool {
        let now = epochNow()
        isWalking = false
        if previousMood != model.state.rawValue {
            previousMood = model.state.rawValue
            if model.state == .done { lastDone = now }
        }
        if model.dragging {
            if active != nil || seek != nil { dragged(model) }
        }
        // Row separation needs the latest moving peer, rather than a half-second-old
        // location. Keep the more expensive meeting/script negotiation on its timer.
        peer = read(peerURL)
        if let p = peer,!p.fresh(now) { peer = nil }
        if now >= nextPoll {
            nextPoll = now+0.5
            if role == .claude,let p = peer { rules.observe(snapshot(model,now: now),p,now: now) }
            if role == .claude,now >= nextDebugPoll {
                nextDebugPoll = now+2
                if let raw = UserDefaults.standard.string(forKey: "forceInteraction") {
                    forcedInteraction = InteractionKind(rawValue: raw)
                    UserDefaults.standard.removeObject(forKey: "forceInteraction")
                }
            }
            if active == nil, !model.dragging, model.grounded,model.trick == nil,model.landing == nil,now >= departUntil,returnX == nil,let p = peer {
                let own = snapshot(model,now: now)
                if role == .claude {
                    let force = seek != nil || (p.seek != nil && p.seek != consumedPeerSeek)
                    let hour = Calendar.current.component(.hour,from: Date(timeIntervalSince1970: now))
                    if let choice = rules.choose(own,p,now: now,hour: hour,inputIdle: inputIdle(),forced: forcedInteraction) {
                        let library = InteractionLines.load(directory.appendingPathComponent("play-lines.json"))
                        let script = InteractionLines.pick(choice.kind,pool: library[choice.kind.rawValue] ?? [],last: rules.lastScript[choice.kind.rawValue])
                        let plan = InteractionPlanner.make(choice,c: own,d: p,now: now,script: script,forced: forcedInteraction != nil)
                        if plan.valid,write(plan,to: planURL) {
                            rules.started(choice,now: now,script: script);write(rules,to: rulesURL)
                            forcedInteraction = nil;accept(plan,model: model,now: now)
                        }
                    } else if (force || now-rules.lastAny >= 60),MeetingRules.canMeet(own,p,now: now,last: history.last,forced: force) {
                        let situation = MeetingRules.situation(own,p,now: now,hour: Calendar.current.component(.hour,from: Date(timeIntervalSince1970: now)))
                        let custom: [String: [MeetingScript]] = read(directory.appendingPathComponent("meet-lines.json")) ?? [:]
                        let pool = (custom[situation] ?? []).filter { !$0.lines.isEmpty && $0.lines.count <= 20 && MeetingDrawing.actions.contains($0.action) }
                        // Small custom pools cannot avoid all three; choose the least recently used script.
                        let script = MeetingRules.select(pool,history: history.scripts,fallback: MeetingRules.fallbacks[situation]!)
                        let plan = MeetingRules.plan(script: script,situation: situation,c: own,d: p,now: now)
                        if write(plan,to: planURL) {
                            consumedPeerSeek = p.seek
                            history.scripts = Array((history.scripts+[script.key]).suffix(3))
                            accept(plan,model: model,now: now)
                        }
                    }
                } else if let plan: MeetingPlan = read(planURL),plan.valid,!history.played.contains(plan.id),
                          (plan.isPlay ? plan.start-now <= 180 : plan.start-now <= 30),now < plan.start+plan.end,
                          plan.screenFor(role) == own.screen,p.screen == plan.screenFor(role.other),p.meetingID == plan.id,p.busy,
                          !p.dragging,p.cancelled != plan.id {
                    accept(plan,model: model,now: now)
                }
            }
            publish(model,now: now)
        }
        if var plan = active {
            // The leader publishes early cheer departure / nap wake on the same plan ID.
            if plan.isPlay,let refreshed: MeetingPlan = read(planURL),refreshed.id == plan.id,refreshed.valid {
                active = refreshed;plan = refreshed
            }
            if role == .claude,let k = plan.interactionKind,var play = plan.play,play.releaseAt == nil {
                let worker = play.subject == role ? model.state.rawValue : peer?.mood ?? "idle"
                let stopCheer = k == .cheer && worker != "working" && worker != "thinking" && !play.forced
                let stopNap = k == .nap && now >= plan.start+plan.actionAt && (inputIdle() < (play.forced ? now-plan.start-plan.actionAt : 600) ||
                    !InteractionRules.idle(snapshot(model,now: now)) || !(peer.map(InteractionRules.idle) ?? false))
                if (stopCheer && now >= plan.start+plan.actionAt) || stopNap {
                    play.releaseAt = now;plan.play = play;plan.end = max(plan.actionAt+0.01,now-plan.start+1)
                    active = plan;write(plan,to: planURL)
                }
            }
            guard !model.dragging,let p = peer,p.fresh(now),p.screen == plan.screenFor(role.other),
                  MeetingPosition.screenID(model.visibleFrame) == plan.screenFor(role),
                  !p.dragging,p.cancelled != plan.id,
                  now <= plan.start+0.9 || (p.busy && p.meetingID == plan.id) else {
                finish(model,now: now,aborted: true);return false
            }
            if now >= plan.start+plan.end { finish(model,now: now) }
            else {
                model.direction = plan.direction(role)
                // Formation stays fixed through the full action, including a hands-only hug.
                let target = plan.playTarget(role,now: now)
                // Hide-seek can exchange left/right order. The seeker walks on an upper
                // lane while approaching, then descends only after horizontal clearance.
                let crossing = plan.interactionKind == .hide_seek && plan.play.map { ($0.originC <= $0.originD) != (plan.claudeX <= plan.codexX) } == true
                if crossing,role == plan.play?.subject.other,now < plan.start {
                    model.position.y = model.floor+ceil(200*plan.scale)
                } else { model.position.y = model.floor }
                move(model,toward: target,dt: dt,allowEdge: plan.interactionKind == .hide_seek && role == plan.play?.subject)
                model.speech = plan.line(at: now,for: role)?.text ?? ""
                if plan.interactionKind == .rps,plan.playAge(now) >= 0,let p = plan.play {
                    let age = plan.playAge(now),round = min(p.rounds.count-1,Int(age/5)),phase = age-Double(round)*5
                    if phase < 3 { model.speech = String(min(3,1+Int(phase))) }
                    else if let winner = p.rounds[round].winner { model.speech = winner == role ? "赢啦！" : "略略～" }
                    else { model.speech = round < 2 ? "平手，再来" : "平手！" }
                }
                model.speechUntil = model.speech.isEmpty ? 0 : uptime+0.1
                return true
            }
        }
        if let target = returnX,!model.dragging,model.grounded {
            let bounded = min(max(target,model.visibleFrame.minX+model.edgeInset),model.visibleFrame.maxX-model.edgeInset)
            model.direction = bounded >= model.position.x ? 1 : -1
            move(model,toward: bounded,dt: dt)
            if abs(model.position.x-bounded) < 1 { returnX = nil;returnPlan = nil;isWalking = false }
            return true
        }
        if now < departUntil,!model.dragging,model.grounded {
            model.direction = departDirection
            move(model,toward: model.position.x+departDirection*100,dt: dt)
            return true
        }
        if seek != nil {
            guard let p = peer,p.fresh(now) else { seek = nil;return false }
            // Walk to the edge of the current screen if the friend is on another display.
            if !model.dragging,model.grounded,model.trick == nil,model.landing == nil {
                model.direction = p.x >= model.position.x ? 1 : -1
                let own = snapshot(model,now: now)
                let distance = role == .claude ? MeetingRules.stageDistance(own,p) : MeetingRules.stageDistance(p,own)
                move(model,toward: p.x-model.direction*distance,dt: dt)
                return true
            }
        }
        return false
    }
    private func move(_ model: PetModel,toward target: CGFloat,dt: Double,allowEdge: Bool = false) {
        isWalking = abs(target-model.position.x) > 0.5
        moveRemainder += dt
        let frames = Int((moveRemainder/0.125).rounded(.down))
        guard frames > 0 else { return };moveRemainder -= Double(frames)*0.125
        let speed: CGFloat = (model.state == .working ? 76 : model.state == .error ? 50 : 25)*model.size.scale
        let step = max(1,(speed*0.125).rounded())*CGFloat(frames)
        var target = target
        if let plan = active ?? returnPlan,plan.isPlay,plan.interactionKind != .fireworks,let p = peer,
           abs(model.position.y-p.y) < 160*plan.scale {
            let side: CGFloat = plan.x(role) < plan.x(role.other) ? -1 : 1
            let separation = abs(plan.claudeX-plan.codexX)
            target = side < 0 ? min(target,p.x-separation) : max(target,p.x+separation)
        }
        let delta = target-model.position.x
        model.position.x = (model.position.x+max(-step,min(step,delta))).rounded()
        if !allowEdge { model.constrainX() }
        model.position.x = model.position.x.rounded()
    }
}

// All action changes are discrete translations, reflections, or row removal, never scaling/rotation/fades.
enum MeetingDrawing {
    static let actions = ["high_five","fist_bump","wave","jump_together","gift","gift_back","hug","spin"]
    static func jumpHeight(plan: MeetingPlan, now: Double, cell: CGFloat) -> CGFloat {
        let t = now-(plan.start+plan.actionAt)
        guard plan.action == "jump_together",t >= 0,t < 2 else { return 0 }
        return [CGFloat(0),1,2,4,6,6,4,2,1,2,4,6,6,4,2,1][min(15,Int(t*8))]*PixelGrid(cell: cell).unit
    }
    static func decorate(_ base: [PixelPrimitive],role: MeetingRole,plan: MeetingPlan,
                         now: Double,anchor: CGPoint,worldX: CGFloat,cell: CGFloat) -> [PixelPrimitive] {
        let grid = PixelGrid(cell: cell),u = grid.unit
        let t = now-(plan.start+plan.actionAt),action = plan.action(at: now) ?? ""
        let toward = plan.direction(role),step = Int(max(0,t)*8)
        let jump = jumpHeight(plan: plan,now: now,cell: cell)
        let squish = action == "hug" && t >= 0.5 ? u : 0
        let mirror = action == "spin" && Int(t*4)%2 == 1
        var result = base.compactMap { p -> PixelPrimitive? in
            var r = p.rect
            if mirror { r.origin.x = 2*anchor.x-r.maxX }
            if squish > 0 {
                let top = max(anchor.y,r.maxY-squish),bottom = max(anchor.y,r.minY-squish)
                r.origin.y = bottom;r.size.height = top-bottom
            }
            r.origin.y += jump + (action == "spin" ? u : 0)
            guard r.height > 0 else { return nil }
            return PixelPrimitive(rect: grid.rect(r),color: p.color,interactive: p.interactive)
        }
        let bodyEdge: CGFloat = role == .claude ? 5*cell : 4.5*cell
        let armColor = role == .claude ? "D97757" : "3A8FD6"
        func rect(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat,_ color: String,_ interactive: Bool = false) {
            let r = grid.rect(CGRect(x: x,y: y,width: w,height: h))
            if r.width > 0 && r.height > 0 { result.append(.init(rect: r,hex: color,interactive: interactive)) }
        }
        // Two arms; only the nearer arm reaches for the partner.
        for side: CGFloat in [-1,1] {
            var height: CGFloat = 4*cell,reach: CGFloat = 2*cell
            if side == toward {
                let groundOffset = max(plan.claudeY,plan.codexY)-plan.y(role)
                if action == "high_five" {
                    let fraction = CGFloat([0,2,4,6,6,6,4,0][min(7,step/2)])/6
                    height = grid.pixel(4*cell+(56*plan.scale+groundOffset-4*cell)*fraction)
                }
                if action == "fist_bump" { height = 32*plan.scale+groundOffset+CGFloat(step%2)*u }
                if action == "wave" {
                    height += CGFloat([2,3,4,3][step%4])*u
                }
                if ["high_five","fist_bump","hug"].contains(action) {
                    let seam = side > 0 ? floor(plan.contactX) : ceil(plan.contactX)
                    reach = max(u,abs(seam-worldX)-bodyEdge)
                    if action == "hug" { height += cell }
                }
                if action == "gift" || action == "gift_back" { height += cell }
                if action == "spin" { height += u }
                if action == "jump_together" { height += u }
            }
            let start = side > 0 ? anchor.x+bodyEdge : anchor.x-bodyEdge-reach
            if side == toward,action == "high_five" {
                let elbow = anchor.x+side*bodyEdge-(side > 0 ? 0 : u)
                rect(elbow,anchor.y+4*cell,u,max(cell,height-4*cell),armColor,true)
            }
            rect(start,anchor.y+height+jump-squish,reach,cell,armColor,true)
        }
        let middle = anchor.x+plan.contactX-worldX
        if role == .claude,(action == "high_five" || action == "fist_bump"),t >= 0.75,t < 1.125 {
            let f = min(2,Int((t-0.75)*8))
            let y = anchor.y+(action == "high_five" ? 56 : 32)*plan.scale+max(plan.claudeY,plan.codexY)-plan.y(role)
            rect(middle-u,y-u,u*2,u*2,"F2C14E")
            if f != 1 { for (dx,dy) in [(-3,0),(3,0),(0,-3),(0,3)] {
                rect(middle+CGFloat(dx)*u,y+CGFloat(dy)*u,u,u,"F2C14E")
            } }
            if f == 2 { rect(middle-2*u,y+2*u,u,u,"FFFFFF") }
        }
        if action == "gift" || action == "gift_back" {
            let sender: MeetingRole = action == "gift" ? .claude : .codex
            if (t < 1 && role == sender) || (t >= 1 && role != sender) {
                let receiver = sender.other,progress = CGFloat(min(1,floor(max(0,t)*12)/12))
                var x: CGFloat,y: CGFloat
                if t < 1 {
                    x = anchor.x+plan.x(sender)-worldX+(plan.x(receiver)-plan.x(sender))*progress
                    let arc = [CGFloat(0),2,3,2][Int(max(0,t)*12)%4]
                    y = anchor.y+10*cell+arc*u
                } else { x = anchor.x;y = anchor.y+13*cell }
                x = grid.snap(x);y = grid.snap(y)
                rect(x-cell,y,2*cell,2*cell,"D8453B")
                rect(x-u/2,y,u,2*cell,"F2C14E");rect(x-cell,y+cell-u/2,2*cell,u,"F2C14E")
            }
        }
        if role == .claude,action == "hug",t >= 0.5 {
            let y = anchor.y+13*cell+CGFloat(min(3,Int((t-0.5)*4)))*u
            for (row,bits) in ["11011","11111","11111","01110","00100"].reversed().enumerated() {
                for (col,bit) in bits.enumerated() where bit == "1" { rect(middle+CGFloat(col-2)*u,y+CGFloat(row)*u,u,u,"F28FB1") }
            }
        }
        return result
    }

}

extension PetModel {
    func quotaPlacement(at now: Date) -> QuotaBattery.Plate? {
        guard let five = quota?.fiveHour else { return nil }
        let grid = PixelGrid(cell: size.uiCell)
        let origin = size.windowOrigin(position: grid.point(position),in: visibleFrame)
        return .init(feetX: grid.snap(position.x),width: QuotaBattery.width(five.remaining(at: now),grid: grid),
                     minX: origin.x,maxX: origin.x+size.canvas.width,unit: grid.unit)
    }
    var meetingExtents: (back: CGFloat,front: CGFloat,top: CGFloat) {
        let anchor = CGPoint(x: 240,y: 80)
        #if DESK_PET
        let base = PixelSprite.primitives(mood: state,act: Act(name: "会面"),outfit: outfit,
            elapsed: 0,anchor: anchor,mirrored: false,walking: false,cell: size.cell,meeting: true)
        let arm = 7*size.uiCell
        #else
        let base = PixelSprite.primitives(mood: state,act: Act(name: "会面"),elapsed: 0,anchor: anchor,
            mirrored: false,walking: false,cell: size.cell,meeting: true,outfit: outfit)
        let arm = 6.5*size.uiCell
        #endif
        let bounds = base.filter(\.interactive).reduce(CGRect.null) { $0.union($1.rect) }
        return (max(arm,anchor.x-bounds.minX),max(arm,bounds.maxX-anchor.x),bounds.maxY-anchor.y)
    }
    var inMeeting: Bool { meeting?.suppressesBubbles == true }
}

extension PetView {
    func separatedQuotaOrigin(now: Date) -> CGPoint {
        let grid = PixelGrid(cell: model.size.uiCell,backingScale: window?.backingScaleFactor ?? 2)
        let left = model.quota?.fiveHour?.remaining(at: now) ?? 100
        var origin = QuotaBattery.origin(under: anchor,left: left,grid: grid)
        let worldX = grid.snap(model.position.x)-anchor.x
        let own = QuotaBattery.Plate(feetX: grid.snap(model.position.x),width: QuotaBattery.width(left,grid: grid),
            minX: worldX+bounds.minX,maxX: worldX+bounds.maxX,unit: grid.unit)
        origin.x = own.centeredX-worldX
        if let meeting = model.meeting,let p = meeting.peer,p.fresh(meeting.epochNow()),
           p.screen == MeetingPosition.screenID(model.visibleFrame),p.grounded,!p.dragging,!p.trick,
           let peer = p.quotaPlate,peer.valid {
            origin.x = QuotaBattery.separatedX(own,from: peer,firstAtTie: meeting.role == .claude)-worldX
        }
        return origin
    }
    var meetingAirborne: Bool {
        guard let meeting = model.meeting,let plan = meeting.active else { return false }
        return (plan.isPlay ? plan.playJump(meeting.role,now: meeting.epochNow(),cell: model.size.uiCell) : MeetingDrawing.jumpHeight(plan: plan,now: meeting.epochNow(),cell: model.size.uiCell)) > 0
    }
    var meetingSprite: [PixelPrimitive]? {
        guard let meeting = model.meeting,meeting.controlsMotion else { return nil }
        let active = meeting.active != nil
        var mood = model.state
        if let plan = meeting.active,let k = plan.interactionKind,let p = plan.play {
            let age = plan.playAge(meeting.epochNow())
            if k == .nap && age >= 0 && p.releaseAt == nil { mood = .sleeping }
            else if k == .comfort && p.subject == meeting.role { mood = age >= 3.8 ? .done : .error }
            else if k != .cheer || meeting.role != p.subject { mood = .idle }
        }
        #if DESK_PET
        let base = PixelSprite.primitives(mood: mood,act: Act(name: "会面",travel: true,walk: true),outfit: model.outfit,
            elapsed: time,anchor: anchor,mirrored: model.direction < 0,walking: meeting.isWalking,
            pixelScale: window?.backingScaleFactor ?? 2,cell: model.size.cell,meeting: active)
        #else
        let base = PixelSprite.primitives(mood: mood,act: Act(name: "会面",travel: true,walk: true),
            elapsed: time,anchor: anchor,mirrored: model.direction < 0,walking: meeting.isWalking,
            pixelScale: window?.backingScaleFactor ?? 2,cell: model.size.cell,meeting: active,outfit: model.outfit)
        #endif
        guard let plan = meeting.active else { return base }
        if plan.isPlay { return InteractionDrawing.decorate(base,role: meeting.role,plan: plan,now: meeting.epochNow(),
            anchor: anchor,worldX: PixelGrid(cell: model.size.uiCell).snap(model.position.x),cell: model.size.uiCell) }
        return MeetingDrawing.decorate(base,role: meeting.role,plan: plan,now: meeting.epochNow(),
            anchor: anchor,worldX: PixelGrid(cell: model.size.uiCell).snap(model.position.x),cell: model.size.uiCell)
    }
}
