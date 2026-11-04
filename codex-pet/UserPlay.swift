import AppKit

// Things the user does to a pet directly (Task 13): eyes that follow the cursor, double-click
// feeding, throwing one pet at the other, and time-of-day greetings. Shared by both apps
// (DeskPet/UserPlay.swift is a relative symlink); it builds on each app's PetModel.

struct UserLines {
    var eat: [String] = []
    var morning: [String] = []
    var late: [String] = []
    var catchScripts: [[(who: MeetingRole, text: String)]] = []

    static func load(_ url: URL, role: MeetingRole) -> UserLines {
        var lines = UserLines()
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return lines }
        lines.eat = ((root["eat"] as? [String: Any])?[role.rawValue] as? [String]) ?? []
        let clock = root["clock"] as? [String: Any]
        lines.morning = ((clock?["morning"] as? [String: Any])?[role.rawValue] as? [String]) ?? []
        lines.late = ((clock?["late"] as? [String: Any])?[role.rawValue] as? [String]) ?? []
        lines.catchScripts = ((root["catch"] as? [[[String: String]]]) ?? []).map { script in
            script.compactMap { l in MeetingRole(rawValue: l["who"] ?? "").map { ($0, l["text"] ?? "") } }
        }
        return lines
    }
}

enum UserAnim: String {
    case feed, refuse, caught, bumped, morning, late
}

final class UserPlay {
    let role = MeetingRole.local
    var lines: UserLines
    private let linesURL: URL
    private var linesStamp: Date?
    private let directory: URL
    private let defaults: UserDefaults

    // Cursor
    private(set) var eyeShift = CGPoint.zero
    private(set) var hold = false
    private var lastCursor = CGPoint(x: -1, y: -1)
    private var cursorStill: Double = 0
    private var fakeCursorUntil: Double = 0

    // One running animation at a time; it decides overlays, mirroring and wobble.
    private(set) var anim: UserAnim?
    private(set) var animStart: Double = 0
    private var animText = ""
    private var feeds: [Double] = []

    // Throwing
    private var samples: [(t: Double, p: CGPoint)] = []
    private(set) var throwVX: CGFloat = 0
    private var throwResolved = false
    private var lastCatchID: String?

    // Speech queued for later (catch dialogue)
    private var queue: [(at: Double, text: String)] = []

    // Clock
    private var lateEligibleSince: Double?
    private var nextSlowPoll: Double = 0

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/pet"),
         defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        linesURL = directory.appendingPathComponent("play-lines.json")
        lines = UserLines.load(linesURL, role: MeetingRole.local)
    }

    static let fallbackEat = ["好吃！", "谢谢你喂我"]
    static let fallbackMorning = ["早上好！"]
    static let fallbackLate = ["该睡觉啦"]

    func duration(_ a: UserAnim) -> Double {
        switch a {
        case .feed: return 2.4
        case .refuse: return 0.6
        case .caught: return 1.2
        case .bumped: return 1.2
        case .morning: return 3
        case .late: return 5
        }
    }

    func active(_ now: Double) -> UserAnim? {
        guard let a = anim, now - animStart < duration(a) else { return nil }
        return a
    }

    func start(_ a: UserAnim, now: Double, text: String = "") {
        anim = a; animStart = now; animText = text
    }

    // MARK: cursor

    // Eye offset in sprite cells (sprite y grows downward). One whole step, never a slide.
    static func eyeOffset(cursor: CGPoint, center: CGPoint, range: CGFloat) -> CGPoint {
        let dx = cursor.x - center.x, dy = cursor.y - center.y
        guard hypot(dx, dy) <= range else { return .zero }
        let x: CGFloat = abs(dx) < range * 0.15 ? 0 : (dx > 0 ? 0.5 : -0.5)
        let y: CGFloat = dy > range * 0.3 ? -0.5 : 0
        return CGPoint(x: x, y: y)
    }

    func updateCursor(_ cursor: CGPoint, body: CGRect, mirrored: Bool, range: CGFloat, blocked: Bool, now: Double) {
        var cursor = cursor
        if now < fakeCursorUntil { cursor = CGPoint(x: body.midX + range * 0.6, y: body.maxY + range * 0.4) }
        if cursor != lastCursor { lastCursor = cursor; cursorStill = now }
        guard !blocked, !body.isNull else { eyeShift = .zero; hold = false; return }
        hold = body.insetBy(dx: -4, dy: -4).contains(cursor) && now - cursorStill >= 2
        var shift = hold ? CGPoint(x: 0, y: -0.5)
            : UserPlay.eyeOffset(cursor: cursor, center: CGPoint(x: body.midX, y: body.midY), range: range)
        if mirrored { shift.x = -shift.x }
        eyeShift = shift
    }

    // MARK: feeding

    // At most 3 feeds a minute; after that the pet shakes its head.
    func feed(now: Double) -> Bool {
        feeds = feeds.filter { now - $0 < 60 }
        guard feeds.count < 3 else { start(.refuse, now: now); return false }
        feeds.append(now)
        let pool = lines.eat.isEmpty ? UserPlay.fallbackEat : lines.eat
        start(.feed, now: now, text: pool.randomElement()!)
        return true
    }

    // MARK: throwing

    func track(_ p: CGPoint, now: Double) {
        samples.append((now, p))
        samples.removeAll { now - $0.t > 0.15 }
    }

    func resetTrack() { samples = [] }

    func releaseVelocity(now: Double) -> CGFloat {
        let recent = samples.filter { now - $0.t <= 0.1 }
        guard let first = recent.first, let last = recent.last, last.t - first.t > 0.01 else { return 0 }
        return (last.p.x - first.p.x) / CGFloat(last.t - first.t)
    }

    static let throwThreshold: CGFloat = 900

    func beginThrow(_ vx: CGFloat) {
        throwVX = max(-2400, min(2400, vx))
        throwResolved = false
    }

    func stopThrow() { throwVX = 0 }

    // Horizontal flight: drag in the air, strong friction once it slides on the ground.
    func stepThrow(x: inout CGFloat, minX: CGFloat, maxX: CGFloat, grounded: Bool, dt: Double) {
        guard throwVX != 0 else { return }
        x += throwVX * CGFloat(dt)
        throwVX *= CGFloat(pow(grounded ? 0.02 : 0.6, dt))
        if x <= minX { x = minX; throwVX = abs(throwVX) * 0.4 }
        if x >= maxX { x = maxX; throwVX = -abs(throwVX) * 0.4 }
        if abs(throwVX) < 40 { throwVX = 0 }
    }

    // Decide once, when the flight reaches the other pet: 70 % caught, 30 % bumped.
    func resolveCatch(x: CGFloat, peer: MeetingPosition?, reach: CGFloat, sameScreen: Bool, epoch: Double, now: Double,
                      roll: Double = Double.random(in: 0..<1)) -> (caught: Bool, x: CGFloat)? {
        guard throwVX != 0, !throwResolved, let p = peer, p.fresh(epoch), p.ready, sameScreen else { return nil }
        let toward = (p.x - x) * throwVX > 0
        guard toward, abs(p.x - x) <= reach else { return nil }
        throwResolved = true
        let side: CGFloat = p.x > x ? -1 : 1
        let caught = roll < 0.7
        let script = lines.catchScripts.randomElement() ?? [(role, "接住啦"), (role.other, "稳稳的")]
        let id = UUID().uuidString
        let plan: [String: Any] = ["id": id, "thrower": role.rawValue, "caught": caught, "at": epoch,
                                   "lines": script.map { ["who": $0.who.rawValue, "text": $0.text] }]
        if let data = try? JSONSerialization.data(withJSONObject: plan) {
            try? data.write(to: directory.appendingPathComponent("catch.json"), options: .atomic)
        }
        lastCatchID = id
        if caught {
            throwVX = 0
            start(.caught, now: now)
            queueLines(script, startingAt: now + 1.2)
        } else {
            throwVX = -throwVX * 0.25
        }
        return (caught, p.x + side * reach)
    }

    func queueLines(_ script: [(who: MeetingRole, text: String)], startingAt t: Double) {
        for (i, l) in script.enumerated() where l.who == role { queue.append((t + Double(i) * 2.6, l.text)) }
    }

    // The other pet reads the thrower's decision and reacts.
    func pollCatch(epoch: Double, now: Double) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("catch.json")),
              let plan = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = plan["id"] as? String, id != lastCatchID,
              plan["thrower"] as? String == role.other.rawValue,
              let at = plan["at"] as? Double, epoch - at < 3 else { return }
        lastCatchID = id
        let caught = plan["caught"] as? Bool ?? false
        start(caught ? .caught : .bumped, now: now)
        if caught {
            let script = ((plan["lines"] as? [[String: String]]) ?? []).compactMap { l in
                MeetingRole(rawValue: l["who"] ?? "").map { ($0, l["text"] ?? "") } }
            queueLines(script, startingAt: now + 1.2 - (epoch - at))
        }
    }

    func dueLine(now: Double) -> String? {
        guard let i = queue.firstIndex(where: { $0.at <= now }) else { return nil }
        return queue.remove(at: i).text
    }

    // MARK: clock

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }

    // Morning: once a day on the first activity at 07:00–09:59. Late: every 30 minutes at
    // 00:00–04:59 while the user is active; 小水滴's slots are a minute after 小橘's.
    func clockEvent(date: Date, inputIdle: Double, now: Double) -> UserAnim? {
        let hour = Calendar.current.component(.hour, from: date)
        if (7..<10).contains(hour), inputIdle < 60, defaults.string(forKey: "morningDay") != UserPlay.dayKey(date) {
            defaults.set(UserPlay.dayKey(date), forKey: "morningDay")
            return .morning
        }
        guard (0..<5).contains(hour), inputIdle < 120 else { lateEligibleSince = nil; return nil }
        if lateEligibleSince == nil { lateEligibleSince = now }
        let offset: Double = role == .codex ? 60 : 0
        let slot = Int((date.timeIntervalSince1970 - offset) / 1800)
        guard defaults.integer(forKey: "lateSlot") != slot, now - lateEligibleSince! >= offset else { return nil }
        defaults.set(slot, forKey: "lateSlot")
        return .late
    }

    func clockLine(_ a: UserAnim) -> String {
        let pool = a == .morning ? lines.morning : lines.late
        return pool.randomElement() ?? (a == .morning ? UserPlay.fallbackMorning : UserPlay.fallbackLate)[0]
    }

    // MARK: per-tick bookkeeping that doesn't need every frame

    // Twice a second: reload lines if changed and read the debug trigger
    // (`defaults write local.deskpet.app forceUserPlay eat|catch|morning|late|mouse`).
    func slowPoll(now: Double) -> (due: Bool, forced: String?) {
        guard now >= nextSlowPoll else { return (false, nil) }
        nextSlowPoll = now + 0.5
        let stamp = (try? linesURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if stamp != linesStamp { linesStamp = stamp; lines = UserLines.load(linesURL, role: role) }
        guard let raw = defaults.string(forKey: "forceUserPlay") else { return (true, nil) }
        defaults.removeObject(forKey: "forceUserPlay")
        if raw == "mouse" { fakeCursorUntil = now + 5 }
        return (true, raw)
    }

    // MARK: drawing

    var blocksWalk: Bool { hold || throwVX != 0 || active(ProcessInfo.processInfo.systemUptime) != nil }

    func mirror(now: Double) -> Bool {
        guard let a = active(now) else { return false }
        let t = now - animStart
        switch a {
        case .feed: return t >= 1.2 && t < 2.0 && Int((t - 1.2) / 0.2) % 2 == 0
        case .refuse: return t < 0.3
        case .caught: return t < 0.8 && Int(t / 0.2) % 2 == 0
        default: return false
        }
    }

    // Whole-unit sideways shake of the bumped pet.
    func wobble(now: Double, unit: CGFloat) -> CGFloat {
        guard active(now) == .bumped else { return 0 }
        let t = now - animStart
        guard t < 0.8 else { return 0 }
        return Int(t / 0.2) % 2 == 0 ? unit : -unit
    }

    func overlay(now: Double, body: CGRect, grid: PixelGrid) -> [PixelFill] {
        guard !body.isNull else { return [] }
        let u = grid.unit
        var out: [PixelFill] = []
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: String) {
            // Half-unit props round to whole device pixels, like every other part of the sprite.
            out.append(PixelFill(rect: CGRect(x: grid.snap(x), y: grid.snap(y), width: max(grid.pixel(w * u), 1 / grid.backingScale), height: max(grid.pixel(h * u), 1 / grid.backingScale)), hex: hex))
        }
        func bits(_ rows: [String], x: CGFloat, y: CGFloat, dot: CGFloat, _ hex: String) {
            for (j, row) in rows.enumerated() {
                for (i, ch) in row.enumerated() where ch == "#" {
                    out.append(PixelFill(rect: CGRect(x: x + CGFloat(i) * dot, y: y + CGFloat(rows.count - 1 - j) * dot,
                                                      width: dot, height: dot), hex: hex))
                }
            }
        }
        let heart = [".#.#.", "#####", ".###.", "..#.."]
        let star = [".#.", "###", ".#."]
        let top = body.maxY, mid = body.midX
        if throwVX != 0 {
            let back: CGFloat = throwVX > 0 ? -1 : 1
            let edge = throwVX > 0 ? body.minX : body.maxX
            for (k, dy) in [CGFloat(1), -1, 3].enumerated() {
                let len = CGFloat(4 - k)
                box(edge + back * (2 + CGFloat(k)) * u - (back < 0 ? len * u : 0), body.midY + dy * u, len, 0.5, "BFC5CC")
            }
        }
        guard let a = active(now) else { return out }
        let t = now - animStart
        switch a {
        case .feed:
            if t < 1.2 {
                let fall = max(0, 8 - CGFloat(Int(t / 0.2)) * 2)
                if role == .claude {
                    let w: CGFloat = t < 0.9 ? 5 : 3
                    box(mid - 2 * u, top + fall * u, w, 2, "9DB4C8")
                    if t < 0.9 { box(mid + 3 * u, top + (fall - 0.5) * u, 2, 3, "9DB4C8"); box(mid - 1.5 * u, top + (fall + 1) * u, 0.5, 0.5, "2B1D1A") }
                } else if t < 0.9 {
                    box(mid - 0.5 * u, top + fall * u, 1, 2, "6CC4F5"); box(mid - 0.5 * u, top + (fall + 2) * u, 0.5, 0.5, "6CC4F5")
                }
            } else {
                bits(heart, x: grid.snap(mid - 2.5 * u), y: grid.snap(top + (2 + CGFloat(Int((t - 1.2) / 0.3))) * u), dot: u, "E85D75")
            }
        case .bumped:
            if Int(t / 0.2) % 2 == 0 {
                for dx in [CGFloat(-4), 0, 4] { bits(star, x: grid.snap(mid + dx * u), y: grid.snap(top + 2 * u), dot: u, "F2C14E") }
            }
        case .caught:
            if t < 1 { bits(star, x: grid.snap(mid - 1.5 * u), y: grid.snap(top + 3 * u), dot: u, "F28FB1") }
        case .morning:
            let sx = body.minX - 7 * u, sy = top + 1 * u
            box(sx, sy, 3, 3, "F2C14E")
            if Int(t / 0.25) % 2 == 0 {
                box(sx + u, sy + 4 * u, 1, 1, "F2C14E"); box(sx + u, sy - 2 * u, 1, 1, "F2C14E")
                box(sx - 2 * u, sy + u, 1, 1, "F2C14E"); box(sx + 4 * u, sy + u, 1, 1, "F2C14E")
            }
        case .late:
            let f = DateFormatter(); f.dateFormat = "H:mm"
            let text = Array(f.string(from: Date()))
            let dot = max(1 / grid.backingScale, grid.pixel(u / 2))
            let signW = CGFloat(text.count) * 4 * dot + 2 * dot, signH = 7 * dot
            let sx = grid.snap(mid - signW / 2), sy = grid.snap(top + 3 * u)
            box(mid - 0.25 * u, top, 0.5, 3, "8B5A2B")
            out.append(PixelFill(rect: CGRect(x: sx, y: sy, width: signW, height: signH), hex: "FFFFFF"))
            out.append(PixelFill(rect: CGRect(x: sx, y: sy, width: signW, height: dot), hex: "9AA0A6"))
            for (i, ch) in text.enumerated() {
                let g = QuotaBattery.glyphs[ch] ?? ""
                let rows = stride(from: 0, to: g.count, by: 3).map { k -> String in
                    String(g.dropFirst(k).prefix(3)).replacingOccurrences(of: "1", with: "#") }
                bits(rows, x: sx + dot + CGFloat(i) * 4 * dot, y: sy + dot, dot: dot, "2F6FB8")
            }
            bits([".###", "##..", "##..", ".###"], x: grid.snap(body.maxX + 2 * u), y: grid.snap(top + 2 * u), dot: u, "F5E7A1")
        case .refuse:
            break
        }
        return out
    }
}

extension PetModel {
    var userBusy: Bool { inMeeting || landing != nil || dragging }

    // Double-click: feed (or shake the head when it has eaten enough).
    func feed(now: TimeInterval) {
        guard !inMeeting && landing == nil else { return }
        if state == .sleeping { transition(to: .idle, now: now) }
        idleSince = now
        trick = nil
        if user.feed(now: now) { speech = user.currentText; speechUntil = now + 3 } else { speechUntil = 0 }
    }

    // Returns true when the release was fast enough to count as a throw.
    func beginThrow(now: TimeInterval) -> Bool {
        let vx = user.releaseVelocity(now: now)
        user.resetTrack()
        guard abs(vx) >= UserPlay.throwThreshold * size.scale else { return false }
        user.beginThrow(vx)
        return true
    }

    func stepUser(dt: TimeInterval, now: TimeInterval) {
        guard user.throwVX != 0 else { return }
        let epoch = Date().timeIntervalSince1970
        let peer = meeting?.peer
        let reach = max(peer?.stageBack ?? 56, peer?.stageFront ?? 56) + 56 * size.scale + size.uiCell
        let sameScreen = peer?.screen == MeetingPosition.screenID(visibleFrame)
        if let hit = user.resolveCatch(x: position.x, peer: peer, reach: reach, sameScreen: sameScreen, epoch: epoch, now: now) {
            position.x = hit.x
            if hit.caught { position.y = floor; velocityY = 0 }
        }
        var x = position.x
        user.stepThrow(x: &x, minX: visibleFrame.minX + edgeInset, maxX: visibleFrame.maxX - edgeInset, grounded: grounded, dt: dt)
        position.x = x
    }

    func tickUser(now: TimeInterval) {
        let epoch = Date().timeIntervalSince1970
        let poll = user.slowPoll(now: now)
        if poll.due {
            switch poll.forced {
            case "eat": feed(now: now)
            case "morning": startClock(.morning, now: now)
            case "late": startClock(.late, now: now)
            case "catch":
                if let p = meeting?.peer, p.fresh(epoch), !userBusy {
                    // Strong enough to reach the other pet from wherever it is.
                    position.y = floor + 120 * size.scale
                    user.beginThrow((p.x > position.x ? 1 : -1) * min(2400, max(900, abs(p.x - position.x) * 2.2)))
                }
            default: break
            }
            user.pollCatch(epoch: epoch, now: now)
            if !userBusy && state != .sleeping && user.active(now) == nil,
               let event = user.clockEvent(date: Date(), inputIdle: MeetingCoordinator.defaultInputIdle(), now: now) {
                startClock(event, now: now)
            }
        }
        if let line = user.dueLine(now: now), landing == nil { speech = line; speechUntil = now + 2.6 }
    }

    func startClock(_ a: UserAnim, now: TimeInterval) {
        guard !userBusy else { return }
        let text = user.clockLine(a)
        user.start(a, now: now, text: text)
        if a == .morning { trick = .jump; trickSince = now }
        speech = text; speechUntil = now + user.duration(a)
    }
}

extension UserPlay {
    var currentText: String { animText }
}
