import AppKit

// Task 12. Decisions and random choices live here; views only consume the frozen plan.
enum InteractionKind: String, Codable, CaseIterable {
    case celebrate, comfort, cheer, give_battery, fireworks, soccer, rps, hide_seek, nap
    var title: String { ["celebrate":"完成庆祝", "comfort":"报错安慰", "cheer":"陪着干活", "give_battery":"递电池", "fireworks":"重置烟花", "soccer":"踢小球", "rps":"石头剪刀布", "hide_seek":"捉迷藏", "nap":"一起打盹"][rawValue]! }
    var cooldown: Double { self == .celebrate || self == .comfort ? 120 : self == .cheer ? 600 : 0 }
    var selfPlay: Bool { [.soccer,.rps,.hide_seek].contains(self) }
}
enum RPSHand: String, Codable, CaseIterable { case rock, paper, scissors }
struct RPSRound: Codable, Equatable {
    var claude: RPSHand, codex: RPSHand
    var winner: MeetingRole? {
        if claude == codex { return nil }
        return (claude == .rock && codex == .scissors) || (claude == .paper && codex == .rock) || (claude == .scissors && codex == .paper) ? .claude : .codex
    }
    func hand(_ role: MeetingRole) -> RPSHand { role == .claude ? claude : codex }
}
struct InteractionChoice: Equatable { var kind: InteractionKind; var subject: MeetingRole }
struct InteractionRules: Codable {
    struct Observation: Codable {
        var mood: String;var quota: Int?;var reset: Double?;var workSince: Double?
        var batteryArmed = true
        var resetSeen: Double? = nil
        var awaitingResetFill: Bool? = nil
    }
    struct Event: Codable { var kind: InteractionKind;var subject: MeetingRole;var at: Double }
    var observed: [String: Observation] = [:]
    var pending: [Event] = []
    var lastKind: [String: Double] = [:]
    var lastScript: [String: String] = [:]
    var lastAny: Double = -1e10
    var idleTimer: Double = 0
    var idleGoal: Double = 0
    var lastObservation: Double? = nil
    static func idle(_ p: MeetingPosition) -> Bool { p.mood == "idle" || p.mood == "sleeping" }
    static func eligible(_ c: MeetingPosition,_ d: MeetingPosition,now: Double) -> Bool {
        c.fresh(now) && d.fresh(now) && c.ready && d.ready && c.screen == d.screen
    }
    mutating func observe(_ c: MeetingPosition,_ d: MeetingPosition,now: Double,choose: (Int)->Int = { Int.random(in: 0..<$0) }) {
        let dt = min(1,max(0,now-(lastObservation ?? now)));lastObservation = now
        if idleGoal == 0 { idleGoal = Double(300+choose(301)) }
        if Self.eligible(c,d,now: now) && Self.idle(c) && Self.idle(d) { idleTimer += dt }
        for (role,p) in [(MeetingRole.claude,c),(.codex,d)] {
            let key = role.rawValue
            let old = observed[key]
            var o = old ?? Observation(mood: p.mood,quota: p.quota5h,reset: p.reset5h,workSince: p.working ? now : nil)
            if let old = old,old.mood != p.mood {
                if p.mood == "done" { pending.append(.init(kind: .celebrate,subject: role,at: now)) }
                if p.mood == "error" { pending.append(.init(kind: .comfort,subject: role,at: now)) }
            }
            if p.working { if o.workSince == nil { o.workSince = now } } else { o.workSince = nil }
            if let q = p.quota5h,q > 25 { o.batteryArmed = true }
            let reset = old?.reset ?? p.reset5h
            let passed = reset.map { $0 <= now && $0 != o.resetSeen } ?? false
            let jumped = old?.quota.flatMap { before in p.quota5h.map { $0-before >= 30 } } ?? false
            // Consume the later quota fill even if it arrives minutes after the clock reset.
            if passed {
                o.resetSeen = reset;o.awaitingResetFill = !jumped
                pending.append(.init(kind: .fireworks,subject: role,at: now))
            } else if jumped {
                if o.awaitingResetFill != true { pending.append(.init(kind: .fireworks,subject: role,at: now)) }
                o.awaitingResetFill = false
            }
            o.mood = p.mood;o.quota = p.quota5h;o.reset = p.reset5h
            observed[key] = o
        }
        pending.removeAll { now-$0.at > 180 }
    }
    func choose(_ c: MeetingPosition,_ d: MeetingPosition,now: Double,hour: Int,inputIdle: Double,
                forced: InteractionKind? = nil,index: (Int)->Int = { Int.random(in: 0..<$0) }) -> InteractionChoice? {
        guard c.fresh(now),d.fresh(now),c.ready,d.ready else { return nil }
        if c.screen != d.screen {
            if forced == .fireworks { return .init(kind: .fireworks,subject: .claude) }
            guard forced == nil,now-lastAny >= 60,let e = pending.first(where: { $0.kind == .fireworks }) else { return nil }
            return .init(kind: .fireworks,subject: e.subject)
        }
        if let k = forced { return .init(kind: k,subject: k == .cheer ? (d.working ? .codex : .claude) : (index(2) == 0 ? .claude : .codex)) }
        guard now-lastAny >= 60 else { return nil }
        func available(_ k: InteractionKind) -> Bool { now-(lastKind[k.rawValue] ?? -1e10) >= k.cooldown }
        for k in [InteractionKind.comfort,.celebrate,.fireworks] where available(k) {
            if let e = pending.first(where: { e in
                let other = e.subject == .claude ? d : c
                return e.kind == k && (k != .celebrate || !other.working)
            }) { return .init(kind: k,subject: e.subject) }
        }
        for (role,p,other) in [(MeetingRole.claude,c,d),(.codex,d,c)] {
            if let q = p.quota5h,q < 20,observed[role.rawValue]?.batteryArmed == true { return .init(kind: .give_battery,subject: role) }
            if p.working,Self.idle(other),let since = observed[role.rawValue]?.workSince,now-since >= 60,available(.cheer) { return .init(kind: .cheer,subject: role) }
        }
        if Self.idle(c) && Self.idle(d) {
            if inputIdle >= 600 && !(7..<10).contains(hour) { return .init(kind: .nap,subject: .claude) }
            if idleTimer >= idleGoal { return .init(kind: [InteractionKind.soccer,.rps,.hide_seek][index(3)],subject: index(2) == 0 ? .claude : .codex) }
        }
        return nil
    }
    mutating func started(_ choice: InteractionChoice,now: Double,script: [MeetingLine],index: (Int)->Int = { Int.random(in: 0..<$0) }) {
        lastAny = now;lastKind[choice.kind.rawValue] = now
        lastScript[choice.kind.rawValue] = InteractionLines.key(script)
        pending.removeAll { $0.kind == choice.kind && $0.subject == choice.subject }
        if choice.kind == .give_battery { observed[choice.subject.rawValue]?.batteryArmed = false }
        if choice.kind.selfPlay { idleTimer = 0;idleGoal = Double(300+index(301)) }
    }
}
enum InteractionLines {
    static func key(_ lines: [MeetingLine]) -> String { lines.map { $0.who.rawValue+":"+$0.text }.joined(separator: "|") }
    static func load(_ url: URL) -> [String: [[MeetingLine]]] {
        // The library also contains round-two dictionaries, so decode only the requested arrays.
        guard let data = try? Data(contentsOf: url),data.count < 262144,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: [[MeetingLine]]] = [:]
        for k in InteractionKind.allCases {
            if let value = raw[k.rawValue],let encoded = try? JSONSerialization.data(withJSONObject: value),
               let scripts = try? JSONDecoder().decode([[MeetingLine]].self,from: encoded) {
                result[k.rawValue] = scripts.filter { !$0.isEmpty && $0.count <= 12 && $0.allSatisfy { !$0.text.isEmpty && $0.text.count <= 84 } }
            }
        }
        return result
    }
    static func pick(_ kind: InteractionKind,pool: [[MeetingLine]],last: String?,index: (Int)->Int = { Int.random(in: 0..<$0) }) -> [MeetingLine] {
        let unique = pool.filter { key($0) != last }
        if !unique.isEmpty { return unique[index(unique.count)] }
        let fallback: [[MeetingLine]] = [
            [.init(who: .claude,text: kind == .nap ? "一起歇一会" : "我来陪你啦"),.init(who: .codex,text: "小水滴来啦")],
            [.init(who: .codex,text: kind == .nap ? "安静打个盹" : "在这里陪你"),.init(who: .claude,text: "一起慢慢来")]]
        return fallback.first(where: { key($0) != last })!
    }
}
struct InteractionPlan: Codable, Equatable {
    var subject: MeetingRole
    var screenC: String? = nil
    var screenD: String? = nil
    var originC: CGFloat, originD: CGFloat
    var topC: CGFloat? = nil
    var topD: CGFloat? = nil
    var kicks: Int = 3
    var miss: MeetingRole? = nil
    var rounds: [RPSRound] = []
    var hideEdge: CGFloat = 0
    var hideSide: CGFloat = -1
    var hideFor: Double = 8
    var hideTravel: Double = 0
    var releaseAt: Double? = nil
    var forced: Bool = false
    func origin(_ role: MeetingRole) -> CGFloat { role == .claude ? originC : originD }
    var valid: Bool {
        [originC,originD,hideEdge,hideSide].allSatisfy(\.isFinite) && (3...5).contains(kicks) &&
        (6...10).contains(hideFor) && hideTravel.isFinite && hideTravel >= 0 && hideTravel < 180 &&
        (1...3).contains(max(1,rounds.count)) && rounds.count <= 3 && (releaseAt?.isFinite ?? true)
    }
}
extension MeetingPlan {
    func screenFor(_ role: MeetingRole) -> String { (role == .claude ? play?.screenC : play?.screenD) ?? screen }
    var interactionKind: InteractionKind? { kind.flatMap(InteractionKind.init(rawValue:)) }
    var isPlay: Bool { interactionKind != nil && play != nil }
    func playAge(_ now: Double) -> Double { now-start-actionAt }
    func playTarget(_ role: MeetingRole,now: Double) -> CGFloat {
        guard let k = interactionKind,let p = play else { return x(role) }
        let t = playAge(now)
        if k == .hide_seek {
            if role == p.subject {
                if t < 0 { return p.hideEdge }
                if t >= 0 && t < p.hideFor {
                    return p.hideEdge-p.hideSide*(Int(t/1.5)%2 == 0 ? 0 : 4*scale)
                }
            } else if t >= 0 && t < p.hideFor {
                // Wandering is outward from the hider, preserving the full sprite gap.
                return x(role)-p.hideSide*CGFloat(Int(t/1.5)%2)*12*scale
            }
        }
        if k == .soccer,let miss = p.miss,role == miss,t >= Double(p.kicks)*1.5,t < Double(p.kicks)*1.5+2 {
            let outward = -direction(role)
            return x(role)+outward*CGFloat([0,12,24,24,12,0][min(5,Int((t-Double(p.kicks)*1.5)*3))])*scale
        }
        return x(role)
    }
    func playJump(_ role: MeetingRole,now: Double,cell: CGFloat) -> CGFloat {
        guard let k = interactionKind,let p = play else { return 0 }
        var t = playAge(now)
        if k == .rps {
            guard let round = p.rounds.last,round.winner == role else { return 0 }
            t -= Double(p.rounds.count-1)*5+3
        } else if k == .hide_seek { t -= p.hideFor+p.hideTravel }
        else if k == .nap { guard let at = p.releaseAt else { return 0 };t = now-at }
        else { return 0 }
        guard t >= 0 && t < 1 else { return 0 }
        return CGFloat([0,1,3,5,6,5,3,1][min(7,Int(t*8))])*PixelGrid(cell: cell).unit
    }
}
enum InteractionPlanner {
    static func make(_ choice: InteractionChoice,c: MeetingPosition,d: MeetingPosition,now: Double,script: [MeetingLine],forced: Bool = false,
                     index: (Int)->Int = { Int.random(in: 0..<$0) }) -> MeetingPlan {
        let k = choice.kind,subject = choice.subject
        var cp = c,dp = d
        cp.stageFront = max(MeetingRules.front(c,role: .claude),c.stageBack ?? 0)
        dp.stageFront = max(MeetingRules.front(d,role: .codex),d.stageBack ?? 0)
        let sign: CGFloat = c.x <= d.x ? 1 : -1
        // Use actual sprite extents for every formation. Extra room is needed for the ball.
        let distance = max(MeetingRules.stageDistance(cp,dp),k == .soccer ? 120*max(c.scale,d.scale) : 0)
        if k == .soccer {
            cp.stageFront = cp.stageFront!+12*c.scale
            dp.stageFront = dp.stageFront!+12*d.scale
        }
        if [.celebrate,.comfort,.cheer,.give_battery].contains(k) {
            if subject == .claude { dp.x = c.x+sign*distance } else { cp.x = d.x-sign*distance }
        }
        var plan = MeetingRules.plan(script: .init(lines: script,action: k == .celebrate ? "high_five" : k == .nap ? "hug" : "wave"),situation: k.rawValue,c: cp,d: dp,now: now)
        plan.kind = k.rawValue
        var p = InteractionPlan(subject: subject,originC: c.x,originD: d.x)
        p.screenC = c.screen;p.screenD = d.screen;p.topC = c.stageTop;p.topD = d.stageTop
        p.forced = forced;p.kicks = 3+index(3);p.miss = index(10) < 3 ? (p.kicks%2 == 1 ? .codex : .claude) : nil
        if k == .rps {
            for _ in 0..<3 {
                let r = RPSRound(claude: RPSHand.allCases[index(3)],codex: RPSHand.allCases[index(3)])
                p.rounds.append(r);if r.winner != nil { break }
            }
        }
        if k == .fireworks { plan.claudeX = c.x;plan.codexX = d.x }
        if k == .hide_seek {
            let h = subject == .claude ? c : d
            let coords = h.screen.split(separator: ",").compactMap { Double($0) }
            let lo = coords.count == 4 ? CGFloat(coords[0]) : (h.minX ?? 0)-100
            let hi = coords.count == 4 ? lo+CGFloat(coords[2]) : (h.maxX ?? 1440)+100
            p.hideSide = abs(h.x-lo) <= abs(hi-h.x) ? -1 : 1
            p.hideEdge = p.hideSide < 0 ? lo : hi
            p.hideFor = Double(6+index(5))
            // The stage is fully on screen. A crossing approach uses an upper walking lane.
            let hu = 4*h.scale,other = subject == .claude ? d : c,ou = 4*other.scale
            let safeH = p.hideSide < 0 ? ceil((h.minX ?? lo+100)/hu)*hu : floor((h.maxX ?? hi-100)/hu)*hu
            let seeker = p.hideSide < 0 ? ceil((safeH+distance)/ou)*ou : floor((safeH-distance)/ou)*ou
            if subject == .claude { plan.claudeX = safeH;plan.codexX = seeker }
            else { plan.codexX = safeH;plan.claudeX = seeker }
            p.hideTravel = Double(ceil(abs(safeH-p.hideEdge)/(max(1,((h.walkSpeed ?? 33*h.scale)*0.125).rounded())*8)))+0.5
        }
        func rate(_ p: MeetingPosition) -> CGFloat { max(1,((p.walkSpeed ?? 33*p.scale)*0.125).rounded())*8 }
        let staging = max(abs(plan.claudeX-c.x)/rate(c),abs(plan.codexX-d.x)/rate(d))
        plan.start = now+(k == .fireworks ? 0.6 : staging+1)
        if k == .hide_seek { plan.start += p.hideTravel }
        plan.lines = script.enumerated().map { .init(who: $0.element.who,text: $0.element.text,at: Double($0.offset)*2.6) }
        plan.actionAt = Double(script.count)*2.6
        var duration: Double = 3
        switch k {
        case .comfort: duration = 4.8
        case .cheer: plan.lines = Array(plan.lines.filter { $0.who == subject.other }.prefix(1));if plan.lines.isEmpty { plan.lines = [.init(who: subject.other,text: "加油，我陪你",at: 0)] };plan.lines[0].at = 0;plan.actionAt = 2.6;duration = 180
        case .soccer: duration = Double(p.kicks)*1.5+(p.miss == nil ? 0 : 2);if plan.lines.count > 1 { let last = plan.lines.removeLast();plan.lines.append(.init(who: last.who,text: last.text,at: plan.actionAt+duration));duration += 2.6 }
        case .rps: duration = Double(p.rounds.count)*5
        case .hide_seek: duration = p.hideFor+p.hideTravel+1;plan.actionAt = 0;plan.lines = script.enumerated().map { .init(who: $0.element.who,text: $0.element.text,at: duration+Double($0.offset)*2.6) };duration += Double(script.count)*2.6
        case .nap: plan.lines = [.init(who: script.first?.who ?? .claude,text: script.first?.text ?? "一起歇一会",at: 0)];plan.actionAt = 2.6;duration = 315360000
        default: break
        }
        plan.end = plan.actionAt+duration;plan.play = p
        return plan
    }
}

// All effects are opaque rectangles. Motion is sampled at 8 Hz and snapped to whole points.
enum InteractionDrawing {
    static let font: [Character: [String]] = ["G":["111","100","101","101","111"],"O":["111","101","101","101","111"],"!":["010","010","010","000","010"],"?":["111","001","011","000","010"],"Z":["111","001","010","100","111"]]
    static func decorate(_ base: [PixelPrimitive],role: MeetingRole,plan: MeetingPlan,now: Double,anchor: CGPoint,worldX: CGFloat,cell: CGFloat) -> [PixelPrimitive] {
        guard let k = plan.interactionKind,let p = plan.play else { return base }
        let t = plan.playAge(now),step = Int(max(0,t)*8),u = PixelGrid(cell: cell).unit,grid = PixelGrid(cell: cell)
        let toward = plan.direction(role),arm = role == .claude ? "D97757" : "3A8FD6"
        let jump = plan.playJump(role,now: now,cell: cell)
        let asleep = k == .nap && t >= 0 && p.releaseAt == nil
        var result = base.map { a -> PixelPrimitive in
            var r = a.rect;r.origin.y += jump
            if asleep && role == .claude && a.color == PixelColor.color("2B1D1A") && abs(r.width-cell) < 1 && r.height < u && r.midY > anchor.y+3*cell { r.size.height = u }
            if k == .soccer && t >= 0 && t < Double(p.kicks)*1.5 {
                let kicker: MeetingRole = Int(t/1.5)%2 == 0 ? .claude : .codex
                if role == kicker && t.truncatingRemainder(dividingBy: 1.5) < 0.375 && r.maxY <= anchor.y+2*cell && r.midX*toward > anchor.x*toward {
                    r.origin.x += toward*cell;r.origin.y += u
                }
            }
            // A seated companion lowers the entire unscaled sprite by one pixel unit.
            if k == .cheer && role == p.subject.other && t >= 0 { r.origin.y -= u }
            return .init(rect: grid.rect(r),color: a.color,interactive: a.interactive)
        }
        func rect(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat,_ color: String,_ touch: Bool = false) {
            let r = grid.rect(CGRect(x: x,y: y,width: w,height: h))
            if r.width > 0 && r.height > 0 { result.append(.init(rect: r,hex: color,interactive: touch)) }
        }
        func local(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat,_ color: String,_ touch: Bool = false) {
            rect(anchor.x+x*cell,anchor.y+y*cell,w*cell,h*cell,color,touch)
        }
        func glyph(_ text: String,_ x: CGFloat,_ y: CGFloat,_ dot: CGFloat,_ color: String) {
            for (i,ch) in text.enumerated() { for (row,bits) in (font[ch] ?? []).reversed().enumerated() { for (col,b) in bits.enumerated() where b == "1" {
                rect(x+CGFloat(i*4+col)*dot,y+CGFloat(row)*dot,dot,dot,color)
            } } }
        }
        func star(_ x: CGFloat,_ y: CGFloat,_ color: String) { rect(x+u,y,u,3*u,color);rect(x,y+u,3*u,u,color) }
        func heart(_ x: CGFloat,_ y: CGFloat) {
            for (row,bits) in ["00100","01110","11111","11011"].enumerated() { for (col,b) in bits.enumerated() where b == "1" { rect(x+CGFloat(col)*u,y+CGFloat(row)*u,u,u,"F28FB1") } }
        }
        func battery(_ x: CGFloat,_ y: CGFloat,_ full: Bool) {
            rect(x,y,4.4*cell,2.2*cell,"3C4043");rect(x+4.4*cell,y+0.6*cell,0.5*cell,cell,"3C4043")
            rect(x+0.3*cell,y+0.3*cell,3.8*cell,1.6*cell,"EEF1F4")
            for i in 0..<(full ? 4 : 1) { rect(x+(0.5+CGFloat(i)*0.9)*cell,y+0.5*cell,0.7*cell,1.2*cell,full ? "2E9E5B" : "D8453B") }
        }
        // Neutral arms (the meeting bases deliberately omit their ordinary arms).
        if k != .celebrate || t < 0 {
            for side: CGFloat in [-1,1] {
                let x = side > 0 ? 5 : -7
                if asleep && side == toward {
                    let seam = grid.pixel(anchor.x+plan.contactX-worldX)
                    rect(min(anchor.x+side*5*cell,seam),anchor.y+4*cell,abs(seam-(anchor.x+side*5*cell)),cell,arm,true);continue
                }
                let y: CGFloat = k == .fireworks && t >= 0 ? 8 : 4
                local(CGFloat(x),CGFloat(y),2,1,arm,true)
                if k == .fireworks && t >= 0 { local(side > 0 ? 5 : -6,4,1,5,arm,true) }
            }
        }
        guard now >= plan.start else { return result }
        switch k {
        case .celebrate:
            if t >= 0 {
                var high = plan;high.kind = nil;high.play = nil;high.action = "high_five";high.end = high.actionAt+3
                result = MeetingDrawing.decorate(base,role: role,plan: high,now: now,anchor: anchor,worldX: worldX,cell: cell)
                if role == .claude {
                    for (i,xy) in [(-6,14),(-3,16),(0,17),(3,16),(6,14)].enumerated() where (step+i)%3 != 0 {
                        star(anchor.x+plan.contactX-worldX+CGFloat(xy.0)*cell,anchor.y+CGFloat(xy.1)*cell,i%2 == 0 ? "F2C14E" : "F28FB1")
                    }
                }
            }
        case .comfort:
            if role == p.subject && t < 3.8 {
                local(-3,14,7,2,"8A939E");local(-2,16,4,1,"8A939E")
                for x: CGFloat in [-2,0,2] { local(x,12-CGFloat(step%4)*0.5,0.3,0.8,"3A8FD6") }
            }
            if role == p.subject.other && t >= 0 && t < 2 {
                // The palm touches the measured head/hat top, with two raised/lowered taps.
                let head = p.subject == .claude ? (p.topC ?? 6.4*cell) : (p.topD ?? 11.25*cell)
                let tip = anchor.x+plan.x(p.subject)-worldX
                let y = grid.pixel(anchor.y+plan.y(p.subject)-plan.y(role)+head)+CGFloat(step%8 < 4 ? 1 : 0)*u
                rect(anchor.x+toward*5*cell,anchor.y+4*cell,cell,y-anchor.y-4*cell,arm,true)
                rect(min(anchor.x+toward*5*cell,tip),y,abs(tip-(anchor.x+toward*5*cell)),cell,arm,true)
                rect(tip-(toward > 0 ? cell : 0),y,cell,cell,arm,true)
            }
            if t >= 2 && t < 3.8 {
                let sender = p.subject.other
                // One owner draws the entire hop, preventing duplicate cookies.
                if role == sender {
                    let f = CGFloat(min(1,floor((t-2)*8)/12))
                    let from = plan.x(sender)+plan.direction(sender)*4*cell,to = plan.x(p.subject)
                    let x = anchor.x+from+(to-from)*f-worldX
                    let y = anchor.y+8*cell+CGFloat([0,1,2,3,3,2,1,0][step%8])*u
                    rect(x,y,2.4*cell,2.4*cell,"B07A45");rect(x+0.5*cell,y+0.5*cell,0.5*cell,0.5*cell,"2B1D1A");rect(x+1.4*cell,y+1.3*cell,0.5*cell,0.5*cell,"2B1D1A")
                }
            }
        case .cheer:
            if role == p.subject.other && t >= 0 {
                let sway: CGFloat = step/4%2 == 0 ? -u : u
                let x = anchor.x-3*cell+sway,y = anchor.y+13*cell
                rect(x+2.5*cell,y-5*cell,0.4*cell,5*cell,"B07A45")
                rect(x,y,6*cell,3.6*cell,"FFFFFF");rect(x,y+3.6*cell-u,6*cell,u,"3C4043")
                glyph("GO!",x+u,y+u,grid.pixel(cell*0.45),"E85D75")
                if step%40 < 8 { heart(anchor.x-2*cell,anchor.y+10*cell+CGFloat(step%8)*u) }
            }
        case .give_battery:
            if role == p.subject && t < 3 && (t >= 1.8 || step%2 == 0) { battery(anchor.x-2.2*cell,anchor.y+14*cell,t >= 1.8) }
            if role != p.subject && t >= 0 && t < 1.8 {
                let f = CGFloat(min(1,floor(max(0,t-0.5)*8)/8))
                let x = anchor.x+toward*4*cell+(plan.x(p.subject)-plan.x(role)-toward*4*cell)*f
                battery(x,anchor.y+8*cell+CGFloat([0,1,2,3,2,1,0,0][step%8])*u,true)
            }
        case .fireworks:
            if t >= 0 && t < 3 {
                // Three bursts across the pair; each is owned by exactly one process.
                for i in 0..<3 where (role == .claude ? i < 2 : i == 2) {
                    let center = (plan.claudeX+plan.codexX)/2
                    let spread = abs(plan.claudeX-plan.codexX) < 400 ? CGFloat(i-1)*7*cell : (role == .claude ? plan.claudeX-center : plan.codexX-center)
                    let x = anchor.x+center+spread-worldX,y = anchor.y+(15+CGFloat(i%2)*2)*cell
                    let radius = CGFloat(1+(step+i*3)%4)*u,color = ["F28FB1","F2C14E","5BD38A"][i]
                    if (step+i)%3 != 0 { for (dx,dy) in [(0,1),(0,-1),(1,0),(-1,0),(1,1),(-1,1),(1,-1),(-1,-1)] { rect(x+CGFloat(dx)*radius,y+CGFloat(dy)*radius,u,u,color) };rect(x,y,u,u,"FFFFFF") }
                }
            }
        case .soccer:
            if t >= 0 && t < Double(p.kicks)*1.5+(p.miss == nil ? 0 : 2) {
                let kick = min(p.kicks-1,Int(t/1.5)),kicker: MeetingRole = kick%2 == 0 ? .claude : .codex
                
                do {
                    let l = min(plan.claudeX,plan.codexX)+56*plan.scale,r = max(plan.claudeX,plan.codexX)-56*plan.scale
                    let from = plan.x(kicker) < plan.x(kicker.other) ? l : r,to = from == l ? r : l
                    var x = from+(to-from)*CGFloat(floor(t.truncatingRemainder(dividingBy: 1.5)*8)/12)
                    if t >= Double(p.kicks)*1.5,let miss = p.miss { x = plan.x(miss)-plan.direction(miss)*CGFloat(min(36,(t-Double(p.kicks)*1.5)*24))*plan.scale }
                    let owner: MeetingRole = abs(x-plan.claudeX) <= abs(x-plan.codexX) ? .claude : .codex
                    guard role == owner else { break }
                    x += anchor.x-worldX
                    rect(x,anchor.y,2*cell,2*cell,"FFFFFF");rect(x+0.6*cell,anchor.y+0.6*cell,0.8*cell,0.8*cell,"2B1D1A")
                    rect(x,anchor.y,2*cell,0.3*cell,"3C4043");rect(x,anchor.y+1.7*cell,2*cell,0.3*cell,"3C4043")
                }
            }
        case .rps:
            if t >= 0,!p.rounds.isEmpty {
                let n = min(p.rounds.count-1,Int(t/5)),phase = t-Double(n)*5,round = p.rounds[n]
                if phase >= 3 {
                    let x = anchor.x-2*cell,y = anchor.y+14*cell,color = role == .claude ? "F2A65A" : "7FB8E6"
                    switch round.hand(role) {
                    case .rock: rect(x,y,3.6*cell,3*cell,color);rect(x,y+2.4*cell,3.6*cell,0.6*cell,arm)
                    case .paper: rect(x,y,3.6*cell,2*cell,color);for i in 0..<4 { rect(x+CGFloat(i)*cell,y+2*cell,0.6*cell,2*cell,color) }
                    case .scissors: rect(x+cell,y,2.4*cell,1.4*cell,arm);rect(x,y+cell,0.9*cell,3.6*cell,color);rect(x+2*cell,y+cell,0.9*cell,3.6*cell,color)
                    }
                    if let winner = round.winner,winner != role,phase < 4.5 { local(-0.5,role == .claude ? 3.5 : 3,1,1.2,"E85D75") }
                }
            }
        case .hide_seek:
            if role != p.subject && t < p.hideFor && step%4 != 0 { glyph("?",anchor.x-cell,anchor.y+14*cell,u,"7B8794") }
        case .nap:
            if asleep {
                for i in 0..<2 { glyph("Z",anchor.x+CGFloat(i*3)*cell,anchor.y+(12+CGFloat(i*2))*cell+CGFloat((step/2+i)%4)*u,u,"7B8794") }
            }
        }
        return result
    }
}
