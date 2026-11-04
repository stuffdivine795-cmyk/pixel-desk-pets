import AppKit

// Native pet scenes and integration. PixelDrawing.swift supplies the shared pixel renderer.
enum PetState: String, Codable, CaseIterable {
    case idle, thinking, working, done, error, sleeping
}

struct PetSignal: Decodable {
    let state: PetState
    let detail: String?
    let ts: Double?
    var outfit: String? = nil
    var quota: QuotaSnapshot? = nil

    static let idle = PetSignal(state: .idle, detail: "", ts: nil)
}

struct FileStamp: Equatable {
    let modified: Date
    let size: UInt64
    let inode: UInt64

    static func read(_ url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        return FileStamp(modified: modified, size: size.uint64Value,
                         inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
}

// Quota is optional and decoded independently from the pet's state.
struct QuotaWindow: Equatable {
    let used: Double
    let resetsAt: Date?
    init?(used: Double?, resetsAt: Date?) {
        guard let used = used, used.isFinite else { return nil }
        self.used = min(100,max(0,used)); self.resetsAt = resetsAt
    }
    func remaining(at now: Date) -> Int {
        if let reset = resetsAt, reset <= now { return 100 }
        return Int((100-used).rounded())
    }
}

struct QuotaSnapshot: Equatable, Decodable {
    var fiveHour: QuotaWindow?
    var sevenDay: QuotaWindow?
    init(fiveHour: QuotaWindow? = nil, sevenDay: QuotaWindow? = nil) {
        self.fiveHour = fiveHour; self.sevenDay = sevenDay
    }
    init(from decoder: Decoder) throws {
        let values = try? decoder.container(keyedBy: Keys.self)
        func window(_ key: Keys) -> QuotaWindow? {
            guard let w = try? values?.nestedContainer(keyedBy: WindowKeys.self,forKey: key) else { return nil }
            let used = try? w.decode(Double.self,forKey: .used)
            let reset = (try? w.decode(String.self,forKey: .resetsAt)).flatMap(LogDate.parse)
            return QuotaWindow(used: used,resetsAt: reset)
        }
        fiveHour = window(.five_hour); sevenDay = window(.seven_day)
    }
    private enum Keys: String, CodingKey { case five_hour, seven_day }
    private enum WindowKeys: String, CodingKey { case used, resetsAt }
    static func codex(_ record: [String: Any]) -> QuotaSnapshot {
        func window(_ key: String) -> QuotaWindow? {
            guard let value = record[key] as? [String: Any] else { return nil }
            let reset = (value["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return QuotaWindow(used: (value["used_percent"] as? NSNumber)?.doubleValue,resetsAt: reset)
        }
        return QuotaSnapshot(fiveHour: window("primary"),sevenDay: window("secondary"))
    }
    func summary(at now: Date) -> String {
        [fiveHour.map { "5h \($0.remaining(at: now))%" },sevenDay.map { "周 \($0.remaining(at: now))%" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
    func menuTitles(at now: Date) -> [String] {
        [("5 小时",fiveHour,"HH:mm"),("每周",sevenDay,"MM-dd HH:mm")].compactMap { name,window,format in
            guard let window = window else { return nil }
            let formatter = DateFormatter(); formatter.dateFormat = format
            let reset = window.resetsAt.map { formatter.string(from: $0) + " 重置" } ?? "重置时间未知"
            return "\(name)：剩 \(window.remaining(at: now))%，\(reset)"
        }
    }
    func addMenuItems(to menu: NSMenu, at now: Date) {
        let titles = menuTitles(at: now)
        guard !titles.isEmpty else { return }
        menu.addItem(.separator())
        for title in titles {
            let item = NSMenuItem(title: title,action: nil,keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
        }
    }
}

enum LogDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds];return f
    }()
    private static let plain = ISO8601DateFormatter()
    static func parse(_ text: String) -> Date? { fractional.date(from: text) ?? plain.date(from: text) }
}


final class StateReader {
    let url: URL
    private var stamp: FileStamp?
    private var didPoll = false

    init(url: URL) { self.url = url }

    // nil means unchanged; missing/invalid input explicitly means idle.
    func poll() -> PetSignal? {
        let current = FileStamp.read(url)
        guard !didPoll || current != stamp else { return nil }
        stamp = current
        didPoll = true
        guard current != nil, let data = try? Data(contentsOf: url),
              let signal = try? JSONDecoder().decode(PetSignal.self, from: data),
              signal.state != .sleeping else { return .idle }
        return signal
    }
}

final class SpeechLines {
    let url: URL
    private var stamp: FileStamp?
    private var loaded = false
    private var custom: [String: [String]] = [:]
    private let defaults: [String: [String]] = [
        "idle": ["我在这里，慢慢来就好。", "今天也要元气满满！", "散散步，等你回来。"],
        "thinking": ["让我想一想……", "灵感马上就来！", "正在认真动脑筋。"],
        "working": ["开工啦，交给我！", "正在努力干活中。", "一步一步，马上就好！"],
        "done": ["完成啦！击个掌！", "搞定，又前进了一小步！", "好耶，辛苦啦！"],
        "error": ["哎呀，遇到一点小麻烦。", "别着急，我们再看看。", "需要你来帮帮忙啦。"],
        "sleeping": ["呼……让我眯一会儿。", "梦里也有小橘子。", "Zzz……我还在哦。"],
        "click": ["嘿，戳到我啦！", "收到你的摸摸啦！"]
    ]

    init(url: URL) { self.url = url }

    func reloadIfChanged() {
        let current = FileStamp.read(url)
        guard !loaded || current != stamp else { return }
        loaded = true
        stamp = current
        guard current != nil, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            custom = [:]
            return
        }
        custom = decoded.mapValues { values in
            values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    func line(for state: PetState, clicked: Bool = false) -> String {
        let choices = custom[state.rawValue].flatMap { $0.isEmpty ? nil : $0 }
            ?? defaults[state.rawValue]!
        let stateLine = choices.randomElement()!
        if clicked {
            let greetings = custom["click"].flatMap { $0.isEmpty ? nil : $0 } ?? defaults["click"]!
            return String((greetings.randomElement()! + " " + stateLine).prefix(84))
        }
        return String(stateLine.prefix(84))
    }
}

// The panel's SVG, expressed in fractional cells; the desktop defaults to 8 pt/cell.
enum Outfit: String, CaseIterable {
    case none, witch, party, crown, headphones, santa, grad, flower
    var title: String {
        ["素颜", "巫师帽", "派对帽", "小王冠", "耳机", "圣诞帽", "学士帽", "小花"][Self.allCases.firstIndex(of: self)!]
    }
}

enum PetSize: String, CaseIterable {
    case small, medium, large
    var cell: CGFloat { self == .small ? 6 : self == .medium ? 8 : 10 }
    var uiCell: CGFloat { cell }
    var scale: CGFloat { cell / 6 }
    var title: String { self == .small ? "小" : self == .medium ? "中" : "大" }
    var canvas: NSSize { NSSize(width: 360 * scale, height: 360 * scale) }
    var anchor: NSPoint { PixelGrid(cell: cell).point(NSPoint(x: 180 * scale, y: 44 * scale)) }
    func windowOrigin(position: NSPoint, in frame: NSRect, backingScale: CGFloat = 2) -> NSPoint {
        let grid = PixelGrid(cell: cell,backingScale: backingScale)
        let position = grid.point(position)
        return grid.point(NSPoint(x: min(max(position.x - anchor.x, frame.minX), max(frame.minX, frame.maxX - canvas.width)),
                y: min(position.y - anchor.y, frame.maxY - canvas.height)))
    }
}

struct Act {
    let name: String
    var body = ""
    var travel = false
    var armL = ""
    var armR = ""
    var look = ""
    var walk = false
    var held = ""
    var front: [String] = []
    var extra = ""
    // Keys for native PixelNode equivalents of the reference's custom SVG fragments.
    var backSvg = ""
    var frontSvg = ""
    var heldSvg = ""
    var hat = ""

    static let all: [PetState: [Act]] = [
        .idle: [
            Act(name: "散步", travel: true, look: "around", walk: true),
            Act(name: "挥手", body: "bob:1.6:2", armR: "wave", look: "around"),
            Act(name: "跳舞", body: "dance:0.8:2", armL: "pumpA", armR: "pumpB", walk: true, extra: "notesR"),
            Act(name: "伸懒腰", body: "stretch:3:3", armL: "reach", armR: "reach", look: "up"),
            Act(name: "喝咖啡", body: "bob:2.4:2", armR: "sip", look: "around", held: "cup"),
            Act(name: "看书", body: "bob:3:2", look: "down", front: ["book"]),
            Act(name: "抛球", armL: "pumpA", armR: "pumpB", look: "up", front: ["juggle"]),
            Act(name: "拍球", body: "bob:0.6:2", armR: "dribble", look: "down", front: ["ball"]),
            Act(name: "变魔术", body: "bob:1.2:2", armR: "cast", look: "up", held: "wand")
        ],
        .thinking: [
            Act(name: "托腮", body: "bob:2.4:2", armR: "chin", look: "up", extra: "thought"),
            Act(name: "踱步", travel: true, armR: "chin", look: "up", walk: true, extra: "thought"),
            Act(name: "灵光一闪", body: "bob:1.2:2", armL: "reach", look: "up", front: ["bulb"])
        ],
        .working: [
            Act(name: "敲键盘", body: "bob:0.5:2", armL: "typeL", armR: "typeR", look: "down", front: ["laptop"]),
            Act(name: "抡锤子", body: "bob:0.5:2", armR: "swing", look: "down", held: "hammer"),
            Act(name: "搬箱子", travel: true, armL: "reach", armR: "reach", walk: true, front: ["box"])
        ],
        .done: [
            Act(name: "欢呼", body: "jump:0.8:4", armL: "up", armR: "up", extra: "confetti"),
            Act(name: "举奖杯", body: "bob:0.8:2", armL: "reach", armR: "reach", front: ["trophy"], extra: "confetti"),
            Act(name: "摇旗", body: "dance:0.8:2", armR: "pumpB", walk: true, held: "flag", extra: "notesL")
        ],
        .error: [
            Act(name: "慌张", body: "shake:0.3:2", armL: "droop", armR: "flail", extra: "panic"),
            Act(name: "晕倒", body: "flat:1:1", armL: "droop", armR: "droop", front: ["stars"]),
            Act(name: "团团转", travel: true, armL: "flail", armR: "flail", walk: true, extra: "sweat")
        ],
        .sleeping: [
            Act(name: "打呼", body: "squish:3:2", armL: "droop", armR: "droop", extra: "zzz"),
            Act(name: "盖被子", body: "squish:3:2", front: ["blanket"], extra: "zzz"),
            Act(name: "鼻涕泡", body: "squish:3:2", armL: "droop", armR: "droop", front: ["bubbleNose"])
        ]
    ]

    static let costumes: [Outfit: [CostumeAct]] = [
        .witch: [
            CostumeAct(Act(name: "骑扫帚", body: "float:1.6:4", extra: "broomSparks", backSvg: "broom"), [.idle, .done]),
            CostumeAct(Act(name: "熬魔药", body: "bob:1.2:2", armR: "stir", look: "down", extra: "potionBubbles", frontSvg: "pot", heldSvg: "spoon"), [.idle, .working])
        ],
        .party: [
            CostumeAct(Act(name: "吹喇叭", body: "bob:0.5:2", armR: "up", extra: "confetti", frontSvg: "horn"), [.idle, .done]),
            CostumeAct(Act(name: "彩带舞", body: "dance:0.6:2", armL: "pumpA", armR: "pumpB", walk: true, heldSvg: "ribbons"), [.idle, .done])
        ],
        .crown: [
            CostumeAct(Act(name: "坐王座", armR: "wave", look: "around", backSvg: "throne"), [.idle, .thinking]),
            CostumeAct(Act(name: "检阅", travel: true, armR: "up", look: "around", walk: true, heldSvg: "scepter"), [.idle])
        ],
        .headphones: [
            CostumeAct(Act(name: "摇头听歌", body: "nod:0.5:2", armL: "pumpA", extra: "notesR"), [.idle, .thinking, .working]),
            CostumeAct(Act(name: "打碟", body: "bob:0.4:2", armL: "typeL", armR: "typeR", look: "down", extra: "djNotes", frontSvg: "decks"), [.idle, .done])
        ],
        .santa: [
            CostumeAct(Act(name: "送礼物", travel: true, walk: true, backSvg: "sack"), [.idle, .done]),
            CostumeAct(Act(name: "下雪啦", armL: "reach", armR: "reach", look: "up", extra: "snow"), [.idle, .sleeping])
        ],
        .grad: [
            CostumeAct(Act(name: "抛帽子", body: "bob:0.8:2", armL: "reach", armR: "reach", look: "up", hat: "toss"), [.idle, .done]),
            CostumeAct(Act(name: "念毕业词", armR: "chin", look: "down", frontSvg: "speechScroll"), [.idle, .thinking])
        ],
        .flower: [
            CostumeAct(Act(name: "浇花", look: "down", extra: "rain", frontSvg: "flowerPot", heldSvg: "wateringCan"), [.idle, .working]),
            CostumeAct(Act(name: "闻花香", body: "sway:2:2", extra: "hearts"), [.idle, .sleeping])
        ],
        .none: [
            CostumeAct(Act(name: "开合跳", body: "hop2:0.8:4", armL: "pumpA", armR: "pumpA", walk: true), [.idle, .done]),
            CostumeAct(Act(name: "吹泡泡", look: "up", extra: "soapBubbles", heldSvg: "bubbleWand"), [.idle, .thinking])
        ]
    ]

    static func costumeActs(outfit: Outfit, mood: PetState) -> [Act] {
        costumes[outfit]!.filter { $0.moods.contains(mood) }.map(\.act)
    }
}

struct CostumeAct {
    let act: Act
    let moods: [PetState]
    init(_ act: Act, _ moods: [PetState]) { self.act = act; self.moods = moods }
}

enum Trick: String, CaseIterable {
    case jump, spin, hop2
    var duration: Double { self == .hop2 ? 0.8 : 0.6 }
    var steps: Int { self == .jump ? 3 : 4 }
}

private enum C {
    static let body = "D97757", ink = "2B1D1A", white = "FFFFFF", cream = "EDE6DA"
    static let gold = "F2C14E", pink = "F28FB1", red = "D8453B", purple = "6E4BB8"
    static let hat = "2E2840", grey = "9AA0A6", dark = "3C4043", sky = "7FB8E6"
    static let wood = "8B5A2B", box = "C8935A", green = "6DBE6A", edge = "9A8A84"
}

// Column-vector affine math makes the SVG hierarchy identical for drawing and hit tests.

enum PixelMotion {
    // CSS steps(n,end) applies to EACH keyframe interval, not to the whole cycle.
    static func sample(_ frames: [(Double, CGFloat)], phase: Double, steps: Int) -> CGFloat {
        if phase <= frames[0].0 { return frames[0].1 }
        for i in 1..<frames.count where phase < frames[i].0 {
            let left = frames[i-1], right = frames[i]
            let fraction = (phase-left.0)/(right.0-left.0)
            let stepped = floor(fraction * Double(steps)) / Double(steps)
            return left.1 + (right.1-left.1)*CGFloat(stepped)
        }
        return frames.last!.1
    }

    fileprivate static func pose(_ name: String, time: Double, duration: Double = 1,
                                 steps: Int = 1, delay: Double = 0, once: Bool = false) -> Pose {
        guard time >= delay else {
            return Pose(opacity: ["pop", "rise", "steam", "note", "z"].contains(name) ? 0 : 1)
        }
        let elapsed = max(0, time-delay)/duration
        let p = once ? min(1, elapsed) : elapsed.truncatingRemainder(dividingBy: 1)
        func v(_ frames: [(Double, CGFloat)]) -> CGFloat { sample(frames, phase: p, steps: steps) }
        func on(_ frames: [(Double, CGFloat)]) -> CGFloat { sample(frames, phase: p, steps: 1) }
        var result = Pose()
        switch name {
        case "look": result.x = v([(0,0),(0.30,0),(0.32,-0.4),(0.52,-0.4),(0.54,0.4),(0.76,0.4),(0.78,0),(1,0)])
        case "blink": result.opacity = on([(0,1),(0.93,1),(0.95,0),(1,0)])
        case "wave": result.y = v([(0,0),(0.30,0),(0.32,-1),(0.40,-2),(0.48,-1),(0.56,-2),(0.64,-1),(0.72,-2),(0.80,0),(1,0)])
        case "sip":
            result.x = v([(0,0),(0.55,0),(0.60,-1.5),(0.85,-1.5),(0.90,0),(1,0)])
            result.y = v([(0,0),(0.55,0),(0.60,-1),(0.85,-1),(0.90,0),(1,0)])
        case "cast": result.y = v([(0,0),(0.5,-1),(1,0)])
        case "bob": result.y = v([(0,0),(0.5,-0.4),(1,0)])
        case "dance":
            result.x = p < 0.5 ? -0.5 : 0.5
            result.y = p < 0.5 ? 0 : -0.5
        case "stretch": result.y = p < 0.5 ? 0 : -0.5
        case "jump": result.y = v([(0,0),(0.5,-2.4),(1,0)])
        case "hop2": result.y = v([(0,0),(0.25,-1.4),(0.5,0),(0.75,-1.4),(1,0)])
        case "spin": result.mirrored = Int(p*4)%2 == 1
        case "shake": result.x = v([(0,-0.5),(0.5,0.5),(1,-0.5)])
        case "squish": result.y = p < 0.5 ? 0 : 0.5
        case "flat": result.angle = p >= 1 ? 90 : 0
        case "legA": result.opacity = p < 0.5 ? 1 : 0
        case "legB": result.opacity = p < 0.5 ? 0 : 1
        case "tap": result.y = v([(0,0),(0.5,0.4),(1,0)])
        case "flail": result.y = v([(0,-1),(0.5,0.5),(1,-1)])
        case "swing": result.angle = p < 0.5 ? -90 : 0
        case "swing2": result.x = v([(0,0),(0.5,0.2),(1,0)])
        case "flick": result.opacity = p < 0.5 ? 1 : 0
        case "page": result.mirrored = p >= 0.5
        case "pop": result.opacity = on([(0,0),(0.3,1),(0.91,0),(1,0)])
        case "fall", "drip":
            result.y = v([(0,0),(1,name == "fall" ? 4 : 1.6)])
            result.opacity = on([(0,1),(0.91,0),(1,0)])
        case "rise":
            result.y = v([(0,0.6),(1,-1.4)])
            result.opacity = on([(0,0),(0.10,1),(0.91,0),(1,0)])
        case "twinkle": result.opacity = p < 0.5 ? 0 : 1
        case "ball": result.y = v([(0,0),(0.5,-2.2),(1,0)])
        case "bulb": result.opacity = p <= 0.4 ? 0 : 1
        case "jug": result.y = v([(0,0),(0.5,-2.6),(1,0)])
        case "orbit":
            result.x = v([(0,-0.6),(0.25,0),(0.5,0.6),(0.75,0),(1,-0.6)])
            result.y = v([(0,0),(0.25,-0.3),(0.5,0),(0.75,0.3),(1,0)])
        case "snot": break // Three separately drawn rectangle sizes; no transform scaling.
        case "float": result.y = v([(0,-0.6),(0.5,-1.6),(1,-0.6)])
        case "nod": result.y = p < 0.5 ? 0 : 0.5
        case "sway": result.x = p < 0.5 ? -0.5 : 0.5
        case "stir":
            // No explicit 100% in the CSS: interpolate back to the underlying identity.
            result.x = v([(0,1),(0.5,2),(1,0)])
            result.y = v([(0,0),(0.5,0.3),(1,0)])
        case "horn": break // Explicit two-cell / four-cell scene variants.
        case "toss": result.y = v([(0,0),(0.5,-4),(1,0)])
        case "snow":
            result.x = v([(0,0),(1,0.6)]); result.y = v([(0,0),(1,7)])
            result.opacity = on([(0,1),(0.91,0),(1,0)])
        case "grow": result.y = p < 0.5 ? 0 : -0.5
        default: break
        }
        result.x = (result.x*2).rounded()/2
        result.y = (result.y*2).rounded()/2
        return result
    }
    static func hornLength(time: Double) -> CGFloat { time.truncatingRemainder(dividingBy: 0.6) < 0.3 ? 2 : 4 }
    static func snotSize(time: Double) -> CGFloat { [CGFloat(0.5),1,1.5][Int(max(0,time).truncatingRemainder(dividingBy: 3))] }
}


final class PixelSprite {
    // Set each tick from the cursor (Task 13); shifts open eyes by one whole step.
    static var eyeShift = CGPoint.zero
    static let cell: CGFloat = 8
    private static func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: String, _ cls: String = "") -> [PixelNode] {
        [.rect(CGRect(x: x, y: y, width: w, height: h), color, cls)]
    }
    private static func g(_ cls: String, _ children: [PixelNode]) -> [PixelNode] { [.group(cls, children)] }

    private static func outfit(_ outfit: Outfit) -> [PixelNode] {
        switch outfit {
        case .witch:
            return r(1.5,-0.7,11,0.7,C.hat) + r(4,-1.6,6,0.9,C.hat) + r(4,-1.3,6,0.4,C.purple) +
                r(5,-2.6,4,1,C.hat) + r(6,-3.5,3,0.9,C.hat) + r(7.5,-4.3,2,0.8,C.hat) + r(9,-4.8,1.2,0.6,C.hat)
        case .party:
            return r(5,-1,4,1,C.pink) + r(5.5,-2,3,1,C.gold) + r(6,-3,2,1,C.pink) +
                r(6.5,-3.8,1,0.8,C.gold) + r(6.3,-4.6,1.4,0.9,C.white)
        case .crown:
            return r(3.5,-1,7,1,C.gold) + r(3.5,-2,1,1,C.gold) + r(6.5,-2,1,1,C.gold) +
                r(9.5,-2,1,1,C.gold) + r(6.6,-0.8,0.8,0.6,C.red)
        case .headphones:
            return r(2.5,-1.3,9,0.6,C.dark) + r(1.9,-0.9,0.7,1.4,C.dark) + r(11.4,-0.9,0.7,1.4,C.dark) +
                r(1.2,0.4,1.2,2,C.dark) + r(11.6,0.4,1.2,2,C.dark) + r(1.4,0.9,0.5,1,C.pink) + r(12.1,0.9,0.5,1,C.pink)
        case .santa:
            return r(3,-1.4,8,1,C.red) + r(4,-2.4,6,1,C.red) + r(5.5,-3.3,4.5,0.9,C.red) +
                r(8.5,-4,3,0.8,C.red) + r(2.6,-0.7,8.8,0.8,C.cream) + r(11.2,-4.5,1.4,1.4,C.cream)
        case .grad:
            return r(4,-1,6,1,C.hat) + r(1.8,-1.8,10.4,0.8,C.hat) + r(6.6,-2.1,0.8,0.4,C.gold) +
                r(11.6,-1.4,0.4,2,C.gold,"tassel") + r(11.4,0.5,0.8,0.6,C.gold,"tassel")
        case .flower:
            return r(9.6,-1.6,1,1,C.pink) + r(10.6,-0.8,1,1,C.pink) + r(9.6,0,1,0.8,C.pink) +
                r(8.6,-0.8,1,1,C.pink) + r(9.6,-0.8,1,1,C.gold) + r(8.2,0.1,0.8,0.5,C.green)
        case .none: return []
        }
    }

    private static func eyes(_ mood: PetState) -> [PixelNode] {
        switch mood {
        case .done:
            return [CGFloat(3.7),8.7].flatMap { (x: CGFloat) -> [PixelNode] in
                var nodes = r(x,1.8,0.4,0.4,C.ink)
                nodes += r(x+0.4,1.4,0.4,0.4,C.ink)
                nodes += r(x+0.8,1.8,0.4,0.4,C.ink)
                return nodes
            }
        case .error:
            return [CGFloat(3.7),8.7].flatMap { (x: CGFloat) -> [PixelNode] in
                var nodes = r(x,1.2,0.4,0.4,C.ink)
                nodes += r(x+0.8,1.2,0.4,0.4,C.ink)
                nodes += r(x+0.4,1.6,0.4,0.4,C.ink)
                nodes += r(x,2,0.4,0.4,C.ink)
                nodes += r(x+0.8,2,0.4,0.4,C.ink)
                return nodes
            }
        case .sleeping: return r(3.8,2,1,0.3,C.ink) + r(8.8,2,1,0.3,C.ink)
        default: return g("blink", r(4.25,1.2,0.5,1,C.ink) + r(9.25,1.2,0.5,1,C.ink))
        }
    }

    private static func held(_ item: String, arm: String) -> [PixelNode] {
        switch item {
        case "cup": return r(12.6,0.4,1.4,1.6,C.cream) + r(12.6,0.4,1.4,0.3,C.wood) + r(14,0.8,0.4,0.7,C.cream) +
            r(12.8,-0.6,0.3,0.6,"CCCCCC","steam") + r(13.4,-1.2,0.3,0.6,"CCCCCC","steam s2")
        case "hammer": return g("hammer \(arm)", r(13,-1.6,0.4,3,C.wood) + r(12.2,-2.2,2,0.8,C.grey))
        case "wand": return g("hammer \(arm)", r(13,-1.6,0.3,3,C.hat) + r(12.7,-2.2,0.9,0.9,C.gold)) +
            r(14.6,-3.4,0.5,0.5,C.gold,"spark s1") + r(15.6,-2,0.4,0.4,C.pink,"spark s2")
        case "flag": return r(13,-3,0.3,4,C.wood) + g("flutter", r(13.3,-3,2.2,1.4,C.red))
        default: return []
        }
    }

    private static func front(_ item: String) -> [PixelNode] {
        switch item {
        case "laptop": return r(3,3.2,8,2.2,C.dark) + r(3.4,3.5,7.2,1.6,C.sky,"screen") + r(2,5.4,10,0.6,C.grey)
        case "book": return r(3.5,2.9,7,2.4,"5B7DB1") + r(4,3.2,3,1.8,"FFF8E7") + r(7,3.2,3,1.8,"FFF8E7") +
            r(7,3.2,3,1.8,"F3EAD6","page") + r(4.4,3.6,2.2,0.2,C.grey) + r(4.4,4.1,2.2,0.2,C.grey)
        case "box": return r(3,-7,8,3,C.box) + r(6.6,-7,0.8,3,"E8C48A")
        case "trophy": return r(5.5,-7,3,1.6,C.gold) + r(4.9,-6.8,0.6,0.8,C.gold) + r(8.5,-6.8,0.6,0.8,C.gold) +
            r(6.5,-5.4,1,0.8,C.gold) + r(5.8,-4.6,2.4,0.5,"B8892B")
        case "blanket": return r(0.5,3,13,3.2,"7C9CC9") + r(0.5,3.6,13,0.4,"A9C0E0") + r(0.5,4.8,13,0.4,"A9C0E0")
        case "ball": return r(16,4.6,1.4,1.4,C.red,"ball")
        case "bulb": return g("bulb", r(6.3,-6.8,1.6,1.6,C.gold) + r(6.6,-5.2,1,0.6,C.grey) +
            r(5,-7.4,0.4,0.4,C.gold) + r(8.8,-7.4,0.4,0.4,C.gold) + r(7,-8,0.3,0.5,C.gold))
        case "juggle": return r(4,-3,0.9,0.9,C.red,"jug j1") + r(6.6,-3,0.9,0.9,C.sky,"jug j2") + r(9.2,-3,0.9,0.9,C.green,"jug j3")
        case "stars": return g("orbit", r(4,-2.4,0.6,0.6,C.gold) + r(7,-3,0.6,0.6,C.gold) + r(10,-2.4,0.6,0.6,C.gold))
        case "bubbleNose": return r(12.2,2.2,1,1,"BFE3F7","snot")
        default: return []
        }
    }

    private static func notes(_ x: CGFloat, _ y: CGFloat) -> [PixelNode] {
        (0..<2).flatMap { i in
            let dx = CGFloat(i)*2, dy = CGFloat(i)
            return g("note n\(i)", r(x+dx,y-dy,0.6,0.5,C.ink) + r(x+dx+0.4,y-dy-1.2,0.2,1.2,C.ink) +
                r(x+dx+0.4,y-dy-1.2,0.7,0.3,C.ink))
        }
    }

    private static func drop(_ x: CGFloat, _ y: CGFloat, _ color: String, _ cls: String) -> [PixelNode] {
        r(x,y,0.4,0.6,color,cls)
    }

    private static func heart(_ x: CGFloat, _ y: CGFloat, _ cls: String) -> [PixelNode] {
        g(cls, r(x,y,0.5,0.5,C.pink) + r(x+0.7,y,0.5,0.5,C.pink) +
            r(x,y+0.4,1.2,0.5,C.pink) + r(x+0.3,y+0.8,0.6,0.4,C.pink))
    }

    private static func flake(_ x: CGFloat, _ y: CGFloat, _ cls: String) -> [PixelNode] {
        g(cls, r(x+0.3,y,0.3,0.9,"9CC3E6") + r(x,y+0.3,0.9,0.3,"9CC3E6"))
    }

    private static func bubble(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ cls: String) -> [PixelNode] {
        g(cls, r(x,y,size,size,"8FC7EA") + r(x+0.15,y+0.15,size-0.3,size-0.3,"EAF6FD") +
            r(x+0.25,y+0.25,0.25,0.25,C.white))
    }

    private static func costumeProp(_ name: String) -> [PixelNode] {
        switch name {
        case "broom": return r(-2,5.2,16,0.5,C.wood) + r(-4,4.6,2.4,1.6,C.gold) + r(-4.4,5,0.6,0.8,"D9A93A")
        case "pot": return r(13.5,3.4,5,2.8,C.hat) + r(13.2,3.2,5.6,0.5,C.dark) + r(13.8,3,4.4,0.5,C.green)
        case "spoon": return r(13.6,0.8,0.3,3,C.wood)
        case "horn": return r(10.5,2.6,0.8,0.5,C.gold) +
            g("horn-short", r(11.3,2.5,2,0.7,C.pink) + r(13.3,2.3,0.6,1.1,C.gold)) +
            g("horn-long", r(11.3,2.5,4,0.7,C.pink) + r(15.3,2.3,0.6,1.1,C.gold))
        case "ribbons": return g("flutter", r(14,0.4,0.5,0.5,C.pink) + r(14.5,0.9,0.5,0.5,C.gold) +
            r(15,0.4,0.5,0.5,C.sky) + r(15.5,0.9,0.5,0.5,C.green))
        case "throne": return r(0.5,-3.5,13,9,C.red) + r(0.5,-3.5,13,0.6,C.gold) +
            r(0.5,-3.5,0.6,9,C.gold) + r(12.9,-3.5,0.6,9,C.gold) + r(6.4,-4.4,1.2,0.9,C.gold)
        case "scepter": return r(13,-3,0.3,4,C.gold) + r(12.6,-3.6,1.1,1.1,C.red)
        case "decks": return r(0.5,3.6,13,2.4,C.dark) +
            g("disc", r(1.5,3.9,4,1.4,"555B60") + r(3,4.3,1,0.6,C.red)) +
            g("disc", r(8.5,3.9,4,1.4,"555B60") + r(10,4.3,1,0.6,C.sky))
        case "sack": return r(-3,0,4.4,4.6,"B33A33") + r(-2.6,-0.8,3.6,1,"B33A33") + r(-1.2,-1.2,0.8,0.5,C.gold)
        case "speechScroll": return r(3,2.8,8,2.6,C.cream) + r(2.6,2.6,0.6,3,"D8CBB4") + r(10.8,2.6,0.6,3,"D8CBB4") +
            r(4,3.3,5.5,0.25,C.grey) + r(4,3.9,6,0.25,C.grey) + r(4,4.5,4,0.25,C.grey) + r(9.4,4.4,0.9,0.9,C.red)
        case "wateringCan": return r(13,1.4,2.4,1.8,C.sky) + r(15.4,1.2,1.4,0.4,C.sky) + r(13.4,0.8,1.6,0.4,C.dark)
        case "flowerPot": return r(16.2,4.8,2,1.6,"B8673C") + r(17,3.6,0.3,1.2,C.green) + r(16.6,2.8,1.1,1,C.pink,"grow")
        case "bubbleWand": return r(13,0.6,0.3,1.8,C.wood) + r(12.7,0,0.9,0.9,C.pink)
        default: return []
        }
    }

    private static func extras(_ name: String) -> [PixelNode] {
        switch name {
        case "notesR": return notes(13,-1)
        case "notesL": return notes(-2,-1)
        case "confetti":
            let bits: [(CGFloat, CGFloat, String)] = [(-3,-3,C.gold),(0,-6,C.pink),(6,-7,C.sky),(12,-6,C.gold),(16,-3,C.pink),(-1,-1,C.green)]
            return bits.enumerated().flatMap { i, bit in r(bit.0,bit.1,0.6,0.6,bit.2,"confetti c\(i % 3)") }
        case "thought": return g("bubble", g("dot d1",r(12.5,-1.7,0.7,0.7,C.edge) + r(12.6,-1.6,0.5,0.5,C.white)) +
            g("dot d2",r(13.2,-2.7,0.9,0.9,C.edge) + r(13.3,-2.6,0.7,0.7,C.white)) +
            g("dot d3", r(13.3,-5.7,2.8,2.6,C.edge) + r(13.4,-5.6,2.6,2.4,C.white) + r(14.3,-5.1,0.8,0.3,C.ink) + r(14.9,-4.8,0.3,0.5,C.ink) +
                r(14.5,-4.3,0.4,0.3,C.ink) + r(14.5,-3.8,0.4,0.3,C.ink)))
        case "zzz": return g("z z1", r(12,-1.5,1.2,0.3,C.ink) + r(12.4,-1.2,0.4,0.4,C.ink) + r(12,-0.8,1.2,0.3,C.ink)) +
            g("z z2", r(13.6,-3.5,1.6,0.4,C.ink) + r(14.2,-3.1,0.5,0.5,C.ink) + r(13.6,-2.6,1.6,0.4,C.ink))
        case "sweat": return r(13,0,0.6,0.6,C.sky,"sweat") + r(12.8,0.6,1,0.8,C.sky,"sweat")
        case "panic": return extras("sweat") + g("smoke", r(11,-3,1.4,1.2,"C9C9C9") + r(12.2,-4.2,1,1,"DDDDDD") + r(13,-5.2,0.7,0.7,"EEEEEE"))
        case "broomSparks": return r(-4,6.2,0.5,0.5,C.purple,"spark s1") + r(-5.5,5.5,0.4,0.4,C.gold,"spark s2")
        case "potionBubbles": return bubble(14.5,1.6,0.8,"pot b1") + bubble(16.4,1.2,0.6,"pot b2") + bubble(15.6,0.4,0.7,"pot b3")
        case "djNotes": return notes(-3,-1) + notes(14,-2)
        case "snow": return flake(-2,-6,"snow s1") + flake(4,-7,"snow s2") + flake(11,-6.5,"snow s3") + flake(16,-5,"snow s1")
        case "rain": return drop(16.8,2.2,C.sky,"rain r1") + drop(17.4,2.2,C.sky,"rain r2")
        case "hearts": return heart(12.5,-2,"love l1") + heart(14.5,-3.5,"love l2")
        case "soapBubbles": return bubble(14,-2,1,"pot b1") + bubble(15.6,-4,1.4,"pot b2") + bubble(13.2,-5.4,0.8,"pot b3")
        default: return []
        }
    }

    // Scene descriptions are immutable; reuse them at 60 fps.
    private static var scenes: [String: ([PixelNode], [PixelNode])] = [:]
    private static func scene(mood: PetState, act: Act, outfit o: Outfit) -> ([PixelNode], [PixelNode]) {
        let key = "\(mood.rawValue)/\(act.name)/\(o.rawValue)"
        if let cached = scenes[key] { return cached }
        let legsA = [CGFloat(3),5,8,10].flatMap { r($0,5,1,1.4,C.body,"legA") }
        let legsB = [CGFloat(2.5),4.5,8.5,10.5].flatMap { r($0,5,1,1.4,C.body,"legB") }
        let body = mood == .sleeping ? r(2,0.6,10,4.4,C.body) : r(2,0,10,5,C.body)
        let frontNodes = act.front.flatMap { front($0) }
        let inFront = act.front.contains { ["laptop", "book", "blanket", "bubbleNose"].contains($0) }
        var nodes = costumeProp(act.backSvg) + legsA + legsB + body + g("look-\(act.look)", eyes(mood)) + g(act.hat, outfit(o))
        if !inFront { nodes += frontNodes }
        nodes += g("arm-\(act.armL)",r(0,2,2,1,C.body))
        nodes += g("arm-\(act.armR)",r(12,2,2,1,C.body) + held(act.held, arm: act.armR) + costumeProp(act.heldSvg))
        if inFront { nodes += frontNodes }
        nodes += costumeProp(act.frontSvg)
        let result = (nodes, extras(act.extra))
        scenes[key] = result
        return result
    }

    private static func motion(_ cls: String, time: Double, act: Act, walk: Bool) -> Pose {
        func animation(_ name: String, _ duration: Double, _ steps: Int = 1, _ delay: Double = 0) -> Pose {
            PixelMotion.pose(name, time: time, duration: duration, steps: steps, delay: delay)
        }
        let words = cls.split(separator: " ").map(String.init)
        let first = words.first ?? ""
        switch first {
        case "blink": var p = animation("blink",3.7); p.x += eyeShift.x; p.y += eyeShift.y; return p
        case "look-up": return Pose(x: 0.2,y: -0.3)
        case "look-down": return Pose(y: 0.4)
        case "look-around": return animation("look",6)
        case "legA": return walk ? animation("legA",0.5) : Pose()
        case "legB": return walk ? animation("legB",0.5) : Pose(opacity: 0)
        case "arm-wave": return animation("wave",3)
        case "arm-chin": return Pose(x: -2,y: 1)
        case "arm-typeL": return animation("tap",0.25)
        case "arm-typeR": return animation("tap",0.25,1,0.12)
        case "arm-up": return Pose(y: -1.6)
        case "arm-reach": return Pose(y: -2.5)
        case "arm-droop": return Pose(y: 0.8)
        case "arm-flail": return animation("flail",0.3)
        case "arm-pumpA": return animation("flail",0.8)
        case "arm-pumpB": return animation("flail",0.8,1,0.4)
        case "arm-sip": return animation("sip",3)
        case "arm-dribble": return animation("tap",0.6)
        case "arm-cast": return animation("cast",1.2)
        case "arm-stir": return animation("stir",0.8,2)
        case "hammer": return words.contains("swing") ? animation("swing",0.5) : Pose()
        case "flutter": return animation("flick",0.4)
        case "screen": return animation("flick",0.6)
        case "page": return animation("page",2,3)
        case "dot": return animation("pop",1.8,1,words.contains("d3") ? 0.6 : words.contains("d2") ? 0.3 : 0)
        case "confetti": return animation("fall",1.2,6,words.contains("c2") ? 0.8 : words.contains("c1") ? 0.4 : 0)
        case "note": return animation("rise",1.6,4,words.contains("n1") ? 0.8 : 0)
        case "sweat": return animation("drip",1.2,4)
        case "smoke": return animation("rise",1.6,4)
        case "steam": return animation("rise",2,4,words.contains("s2") ? 1 : 0)
        case "spark": return animation("twinkle",0.6,2)
        case "tassel": return animation("swing2",1.2,2)
        case "ball": return animation("ball",0.6,3)
        case "bulb": return animation("bulb",1.5)
        case "jug": return animation("jug",0.9,4,words.contains("j3") ? 0.6 : words.contains("j2") ? 0.3 : 0)
        case "orbit": return animation("orbit",0.8,4)
        case "snot": return animation("snot",3,4)
        case "z": return animation("rise",2.4,4,words.contains("z2") ? 1.2 : 0)
        case "pot": return animation("rise",1.4,4,words.contains("b3") ? 0.9 : words.contains("b2") ? 0.45 : 0)
        case "horn-short": return Pose(opacity: PixelMotion.hornLength(time: time) == 2 ? 1 : 0)
        case "horn-long": return Pose(opacity: PixelMotion.hornLength(time: time) == 4 ? 1 : 0)
        case "disc": return animation("flick",0.25)
        case "toss": return animation("toss",1.6,6)
        case "snow": return animation("snow",2.4,8,words.contains("s3") ? 1.6 : words.contains("s2") ? 0.8 : 0)
        case "rain": return animation("drip",0.8,4,words.contains("r2") ? 0.4 : 0)
        case "grow": return animation("grow",2.4,3)
        case "love": return animation("rise",2,4,words.contains("l2") ? 1 : 0)
        default: return Pose()
        }
    }

    static func primitives(mood: PetState, act: Act, outfit: Outfit, elapsed: Double,
                           anchor: CGPoint, mirrored: Bool, walking: Bool,
                           trick: Trick? = nil, trickTime: Double = 0, squash: CGFloat = 0,
                           pixelScale: CGFloat = 2, cell: CGFloat = PixelSprite.cell, meeting: Bool = false) -> [PixelPrimitive] {
        let (rawNodes, rawExtra) = scene(mood: mood, act: meeting ? Act(name: "会面") : act, outfit: outfit)
        let nodes = meeting ? rawNodes.filter { node in
            if case .group(let cls,_) = node { return !cls.hasPrefix("arm-") };return true
        } : rawNodes
        let extra = meeting ? [] : rawExtra
        let grid = PixelGrid(cell: cell,backingScale: pixelScale)
        let anchor = grid.point(anchor)
        let base = PixelTransform(a: cell,d: -cell,tx: grid.pixel(anchor.x-7*cell),ty: grid.pixel(anchor.y+6.4*cell))
        let facing = mirrored ? PixelTransform.translate(14,0).times(.mirror) : PixelTransform()
        let world = base.times(facing)
        let box = nodes.reduce(CGRect.null) { $0.union($1.bounds) }
        let origin = act.body.hasPrefix("flat:") ? CGPoint(x: 7,y: 2.5) : CGPoint(x: box.midX,y: box.maxY)
        var bodyPose = Pose()
        let body = act.body.split(separator: ":").map(String.init)
        if body.count == 3, let duration = Double(body[1]), let steps = Int(body[2]) {
            bodyPose = PixelMotion.pose(body[0],time: elapsed,duration: duration,steps: steps,once: body[0] == "flat")
        }
        // CSS animations of the same property use the last active animation (the poke).
        if let trick = trick, trickTime < trick.duration {
            bodyPose = PixelMotion.pose(trick.rawValue,time: trickTime,duration: trick.duration,steps: trick.steps,once: true)
        }
        if bodyPose.angle == 90 { bodyPose.y = -3.5 }
        var petTransform = world.times(bodyPose.transform(around: origin,grid: grid))
        // Landing is a one-unit bob, never a scale transform.
        if squash > 0 { petTransform = petTransform.times(Pose(y: 0.5).transform(around: .zero,grid: grid)) }
        var result: [PixelPrimitive] = []
        func visit(_ node: PixelNode, parent: PixelTransform, opacity: CGFloat, interactive: Bool) {
            let cls: String
            switch node { case .rect(_,_,let c): cls = c; case .group(let c,_): cls = c }
            let pose = motion(cls,time: elapsed,act: act,walk: walking)
            let alpha = opacity * pose.opacity
            precondition(alpha == 0 || alpha == 1)
            guard alpha == 1 else { return }
            var pivot = CGPoint.zero
            if cls.hasPrefix("hammer") { pivot = CGPoint(x: node.bounds.midX,y: node.bounds.maxY) }
            if cls == "page" || cls == "snot" { pivot = CGPoint(x: node.bounds.minX,y: node.bounds.midY) }
            if cls == "horn" { pivot = CGPoint(x: node.bounds.minX,y: node.bounds.midY) }
            if cls == "grow" { pivot = CGPoint(x: node.bounds.midX,y: node.bounds.maxY) }
            let transform = parent.times(pose.transform(around: pivot,grid: grid))
            switch node {
            case .group(_,let children):
                for child in children { visit(child,parent: transform,opacity: alpha,interactive: interactive) }
            case .rect(let rect,let hex,_):
                var rect = rect
                if cls == "snot" {
                    let side = PixelMotion.snotSize(time: elapsed)
                    rect.size = CGSize(width: side,height: side)
                }
                if let primitive = PixelPrimitive.transformed(rect,by: transform,grid: grid,hex: hex,interactive: interactive) {
                    result.append(primitive)
                }
            }
        }
        for node in nodes { visit(node,parent: petTransform,opacity: 1,interactive: true) }
        for node in extra { visit(node,parent: world,opacity: 1,interactive: false) }
        return result
    }

    static func draw(_ primitives: [PixelPrimitive], in context: CGContext) {
        context.saveGState()
        PixelDrawing.crisp(context)
        for primitive in primitives {
            context.setFillColor(primitive.color)
            context.fill(primitive.rect)
        }
        context.restoreGState()
    }
}

final class PetModel {
    var landing: LandingRun?
    var lastLanding: LandingTrick?
    var landingClock: Double = 0
    var landingLines = LandingLines()
    var meeting: MeetingCoordinator?
    var state: PetState = .idle
    var externalState: PetState = .idle
    var detail = ""
    var quota: QuotaSnapshot?
    var stateSince: TimeInterval
    var idleSince: TimeInterval
    var position: NSPoint
    var visibleFrame: NSRect
    var direction: CGFloat = -1
    var velocityY: CGFloat = 0
    var dragging = false
    var quiet = false
    var landingSquash: CGFloat = 0
    var actIndex = 0
    var actSince: TimeInterval
    var nextAct: TimeInterval
    var trick: Trick?
    var trickSince: TimeInterval = 0
    let user = UserPlay()
    private var travelRemainder: TimeInterval = 0
    private let preferences: UserDefaults
    private(set) var localOutfit: Outfit
    // The outfit the panel last wrote to state.json; a new value there replaces the menu choice
    private var lastFileOutfit: String?
    private(set) var size: PetSize
    var outfit: Outfit { localOutfit }
    var availableActs: [Act] { Act.all[state]! + Act.costumeActs(outfit: outfit, mood: state) }
    var act: Act { availableActs[actIndex % availableActs.count] }
    var nextPause: TimeInterval
    var pauseUntil: TimeInterval = 0
    var speech = ""
    var speechUntil: TimeInterval = 0
    let lines: SpeechLines

    var floor: CGFloat { visibleFrame.minY + QuotaBattery.groundHeight(cell: size.uiCell) }
    // The quota plate fits within the existing costume margin.
    var edgeInset: CGFloat { min(13 * size.cell, visibleFrame.width / 2) }
    var grounded: Bool { position.y <= floor + 0.5 && velocityY == 0 }
    var walking: Bool { meeting?.controlsMotion != true && !quiet && !dragging && grounded && act.travel && trick == nil && landing == nil && !user.blocksWalk }
    var moving: Bool { walking && (state != .idle || clock >= pauseUntil) }
    private var clock: TimeInterval = 0

    init(frame: NSRect, lines: SpeechLines, now: TimeInterval, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        localOutfit = preferences.string(forKey: "outfit").flatMap(Outfit.init(rawValue:)) ?? .witch
        size = preferences.string(forKey: "size").flatMap(PetSize.init(rawValue:)) ?? .medium
        actSince = now
        nextAct = now + 9
        clock = now
        self.lines = lines
        visibleFrame = frame
        position = NSPoint(x: frame.maxX - min(150 * size.scale, frame.width / 2), y: frame.minY + QuotaBattery.groundHeight(cell: size.uiCell))
        stateSince = now
        idleSince = now
        nextPause = now + 5
        chooseAct(now: now, avoidingCurrent: false)
    }

    func chooseOutfit(_ outfit: Outfit) {
        let previous = self.outfit
        localOutfit = outfit
        preferences.set(outfit.rawValue, forKey: "outfit")
        if self.outfit != previous { chooseAct(now: clock, avoidingCurrent: false) }
    }

    func chooseSize(_ size: PetSize) {
        let onFloor = grounded
        self.size = size
        preferences.set(size.rawValue, forKey: "size")
        if onFloor { position.y = floor }
        if !dragging && meeting?.active?.interactionKind != .hide_seek { constrainX() }
    }

    func chooseAct(now: TimeInterval, avoidingCurrent: Bool = true) {
        let count = Act.all[state]!.count
        let costumeCount = Act.costumeActs(outfit: outfit, mood: state).count
        // Like actOf(): choose a costume act about half the time, if this mood permits it.
        let pool = costumeCount > 0 && Bool.random() ? Array(count..<(count + costumeCount)) : Array(0..<count)
        let choices = avoidingCurrent && pool.count > 1 ? pool.filter { $0 != actIndex } : pool
        // A one-act costume pool may repeat, as in the reference; keep the 50/50 weighting.
        actIndex = choices.randomElement()!
        actSince = now
        nextAct = now + 9
        travelRemainder = 0
    }

    func say(_ state: PetState, now: TimeInterval, clicked: Bool = false) {
        guard !inMeeting && landing == nil else { return }
        speech = lines.line(for: state, clicked: clicked)
        speechUntil = now + 3
    }

    func transition(to newState: PetState, now: TimeInterval) {
        guard state != newState else { return }
        state = newState
        stateSince = now
        if newState == .idle { idleSince = now }
        chooseAct(now: now, avoidingCurrent: false)
        say(newState, now: now)
    }

    func receive(_ signal: PetSignal, now: TimeInterval) {
        quota = signal.quota
        detail = String((signal.detail ?? "").prefix(80))
        // The panel's 换装 and this menu share one outfit: whichever changed it last wins.
        let previous = outfit
        if let raw = signal.outfit, raw != lastFileOutfit {
            lastFileOutfit = raw
            if let fileOutfit = Outfit(rawValue: raw) {
                localOutfit = fileOutfit
                preferences.set(raw, forKey: "outfit")
            }
        }
        if signal.state == externalState {
            if outfit != previous { chooseAct(now: now, avoidingCurrent: false) }
            return
        }
        externalState = signal.state
        if state == signal.state && outfit != previous { chooseAct(now: now, avoidingCurrent: false) }
        transition(to: signal.state, now: now)
    }

    func click(now: TimeInterval) {
        guard !inMeeting && landing == nil else { return }
        let clickedState = state
        if state == .sleeping { transition(to: .idle, now: now) }
        if state == .idle { idleSince = now }
        say(clickedState, now: now, clicked: true)
        trick = Trick.allCases.randomElement()!
        trickSince = now
    }

    func setScreen(_ frame: NSRect) {
        let wasGrounded = grounded
        visibleFrame = frame
        if wasGrounded && !dragging { position.y = floor }
        if !dragging && meeting?.active?.interactionKind != .hide_seek { constrainX() }
    }

    func constrainX() {
        position.x = min(max(position.x, visibleFrame.minX + edgeInset), visibleFrame.maxX - edgeInset)
    }

    func releaseDrag(now: TimeInterval) {
        let dropHeight = max(0,position.y-floor)
        dragging = false
        constrainX()
        position.y = min(max(position.y, floor), max(floor, visibleFrame.maxY - 112 * size.scale))
        velocityY = 0
        idleSince = now
        if state == .sleeping { transition(to: .idle, now: now) }
        if !beginThrow(now: now) { beginLanding(height: dropHeight,now: now) }
    }

    func step(dt: TimeInterval, now: TimeInterval) {
        defer { meeting?.publishPosition(self) }
        if state == .done && now - stateSince >= 6 { transition(to: .idle, now: now) }
        if state == .idle && now - idleSince >= 180 && !dragging && !inMeeting {
            transition(to: .sleeping, now: now)
        }
        clock = now
        let wasLanding = landing != nil
        if wasLanding {
            // Keep the shared position heartbeat fresh; landing snapshots are never ready to meet.
            _ = meeting?.update(self,dt: dt,uptime: now)
            if stepLanding(dt: dt,now: now) { return }
        }
        if !wasLanding,meeting?.update(self,dt: dt,uptime: now) == true { return }
        if now >= nextAct { chooseAct(now: now) }
        if let active = trick, now - trickSince >= active.duration { trick = nil }
        landingSquash = max(0, landingSquash - CGFloat(dt) * 4)
        guard !dragging else { return }
        stepUser(dt: dt, now: now)
        if position.y > floor || velocityY != 0 {
            velocityY -= 1_600 * CGFloat(dt)
            position.y += velocityY * CGFloat(dt)
            if position.y <= floor {
                position.y = floor
                landingSquash = min(1, abs(velocityY) / 400)
                velocityY = 0
            }
        }
        guard walking else { return }
        if state == .idle {
            if now >= nextPause {
                pauseUntil = now + Double.random(in: 0.8...2.4)
                nextPause = pauseUntil + Double.random(in: 4...10)
            }
            if now < pauseUntil { return }
        }
        // The panel's travel has 36 steps per half of a 9 s cycle: 0.125 s/frame.
        travelRemainder += dt
        let frames = (travelRemainder / 0.125).rounded(.down)
        travelRemainder -= frames * 0.125
        let speed: CGFloat = (state == .working ? 76 : state == .error ? 50 : 25) * size.scale
        position.x += direction * speed * CGFloat(frames * 0.125)
        let edge = edgeInset
        if position.x <= visibleFrame.minX + edge {
            position.x = visibleFrame.minX + edge
            direction = 1
        } else if position.x >= visibleFrame.maxX - edge {
            position.x = visibleFrame.maxX - edge
            direction = -1
        }
    }
}

final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class PetView: NSView {
    var anchor: NSPoint
    let model: PetModel
    weak var controller: PetController?
    var time: TimeInterval = 0
    private var mouseOrigin: NSPoint?
    private var petOrigin = NSPoint.zero
    private var didDrag = false

    init(model: PetModel) {
        self.model = model
        anchor = model.size.anchor
        super.init(frame: NSRect(origin: .zero, size: model.size.canvas))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("小橘桌宠；点击打招呼，拖动移动，右键打开菜单")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isOpaque: Bool { false }
    var holdingMouse: Bool { mouseOrigin != nil }

    var sprite: [PixelPrimitive] {
        if let pixels = landingSprite { return pixels }
        if let pixels = meetingSprite { return pixels }
        return PixelSprite.primitives(mood: model.state, act: model.act, outfit: model.outfit,
                               elapsed: max(0,time-model.actSince), anchor: NSPoint(x: anchor.x+model.user.wobble(now: time,unit: model.size.uiCell/2),y: anchor.y),
                               mirrored: (model.act.travel && model.direction < 0) != model.user.mirror(now: time),
                               walking: model.act.walk && (!model.act.travel || model.moving),
                               trick: model.trick, trickTime: max(0,time-model.trickSince),
                               squash: model.landingSquash, pixelScale: window?.backingScaleFactor ?? 2,
                               cell: model.size.cell)
    }

    var bodyRect: NSRect {
        sprite.filter(\.interactive).reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
    }

    func containsCharacter(_ point: NSPoint) -> Bool {
        sprite.contains { $0.interactive && $0.path.contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        (holdingMouse || containsCharacter(point)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseOrigin = NSEvent.mouseLocation
        petOrigin = model.position
        didDrag = false
        model.user.resetTrack()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseOrigin else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - start.x, dy = mouse.y - start.y
        guard didDrag || hypot(dx, dy) > 3 else { return }
        didDrag = true
        model.beginDrag(now: ProcessInfo.processInfo.systemUptime)
        model.velocityY = 0
        model.position = NSPoint(x: petOrigin.x + dx, y: petOrigin.y + dy)
        model.user.track(mouse, now: ProcessInfo.processInfo.systemUptime)
        controller?.selectScreen(at: mouse)
        controller?.placeWindow()
    }

    override func mouseUp(with event: NSEvent) {
        guard holdingMouse else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if didDrag {
            controller?.selectScreen(at: NSEvent.mouseLocation)
            model.releaseDrag(now: now)
        } else if event.clickCount >= 2 {
            model.feed(now: now)
        } else {
            model.click(now: now)
        }
        mouseOrigin = nil
        didDrag = false
        controller?.placeWindow()
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let find = NSMenuItem(title: "去找小水滴",action: #selector(findFriend),keyEquivalent: "")
        find.target = self;menu.addItem(find)
        let quiet = NSMenuItem(title: model.quiet ? "继续走动" : "安静一会",
                              action: #selector(toggleQuiet), keyEquivalent: "")
        quiet.target = self
        menu.addItem(quiet)
        let costumes = NSMenuItem(title: "换装", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "换装")
        for outfit in Outfit.allCases {
            let item = NSMenuItem(title: outfit.title, action: #selector(changeOutfit(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = outfit.rawValue
            item.state = model.outfit == outfit ? .on : .off
            submenu.addItem(item)
        }
        costumes.submenu = submenu
        menu.addItem(costumes)
        let sizes = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: "大小")
        for size in PetSize.allCases {
            let item = NSMenuItem(title: size.title, action: #selector(changeSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            item.state = model.size == size ? .on : .off
            sizeMenu.addItem(item)
        }
        sizes.submenu = sizeMenu
        menu.addItem(sizes)
        let testing = NSMenuItem(title: "互动测试",action: nil,keyEquivalent: "")
        let tests = NSMenu(title: "互动测试")
        for kind in InteractionKind.allCases {
            let item = NSMenuItem(title: kind.title,action: #selector(testInteraction(_:)),keyEquivalent: "")
            item.target = self;item.representedObject = kind.rawValue;tests.addItem(item)
        }
        testing.submenu = tests;testing.isHidden = true;testing.keyEquivalentModifierMask = [.option]
        // Option-right-click reveals this debug-only menu.
        if NSEvent.modifierFlags.contains(.option) { testing.isHidden = false }
        menu.addItem(testing)
        model.quota?.addMenuItems(to: menu,at: Date())
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func changeOutfit(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let outfit = Outfit(rawValue: raw) else { return }
        model.chooseOutfit(outfit)
        needsDisplay = true
    }

    @objc private func testInteraction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,let kind = InteractionKind(rawValue: raw) else { return }
        model.meeting?.forcedInteraction = kind
    }
    @objc private func findFriend() { model.meeting?.findFriend(model) }
    @objc private func toggleQuiet() { model.quiet.toggle() }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }

    @objc private func changeSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = PetSize(rawValue: raw) else { return }
        model.chooseSize(size)
        controller?.placeWindow()
        needsDisplay = true
    }

    // Set by the controller: the live window shows its pre-rendered frame instead of drawing again.
    weak var frameGate: FrameGate?
    override func draw(_ dirtyRect: NSRect) {
        if frameGate?.present(in: dirtyRect,bounds: bounds) == true { return }
        draw(dirtyRect, now: Date())
    }

    // A fixed wall clock lets offscreen checks render quota fixtures after their reset date.
    func draw(_ dirtyRect: NSRect, now: Date) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let grid = PixelGrid(cell: model.size.cell,backingScale: window?.backingScaleFactor ?? 2)
        context.saveGState(); PixelDrawing.crisp(context)
        for fill in PixelDrawing.shadow(at: anchor,height: max(0,model.position.y-model.floor),grid: grid,width: 40) { fill.draw(in: context) }
        context.restoreGState()
        let pixels = sprite
        PixelSprite.draw(pixels,in: context)
        let spriteBox = pixels.reduce(CGRect.null) { $0.union($1.rect) }
        // Props drawn for the user's actions; the bubble moves up above them.
        let extras = model.user.overlay(now: time,body: spriteBox,grid: PixelGrid(cell: model.size.uiCell,backingScale: grid.backingScale))
        for fill in extras { fill.draw(in: context) }
        if quotaPlateVisible {
            QuotaBattery.draw(model.quota,at: batteryOrigin(now: now),cell: model.size.uiCell,
                              now: now,in: context,pixelScale: grid.backingScale)
        }
        let rect = extras.reduce(pixels.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }) { $0.union($1.rect) }
        drawBubble(above: rect)
    }

    var quotaPlateVisible: Bool { !model.dragging && model.grounded && model.trick == nil && !actIsAirborne && !meetingAirborne && !model.landingAirborne }

    // Animated jumps can leave the floor while the model's physical position stays grounded.
    var actIsAirborne: Bool {
        guard !model.inMeeting && model.landing == nil else { return false }
        let body = model.act.body.split(separator: ":").map(String.init)
        guard body.count == 3,["jump","hop2","float"].contains(body[0]),
              let duration = Double(body[1]),let steps = Int(body[2]) else { return false }
        return PixelMotion.pose(body[0],time: max(0,time-model.actSince),duration: duration,steps: steps).y != 0
    }

    var batteryOrigin: CGPoint { batteryOrigin(now: Date()) }
    func batteryOrigin(now: Date) -> CGPoint {
        separatedQuotaOrigin(now: now)
    }

    func bubbleLayout(above r: NSRect) -> PixelBubble.Layout? {
        let text = time < model.speechUntil ? model.speech : ""
        let thinking = !model.inMeeting && model.state == .thinking, working = !model.inMeeting && model.state == .working
        guard !text.isEmpty || thinking || working else { return nil }
        let grid = PixelGrid(cell: model.size.cell,backingScale: window?.backingScaleFactor ?? 2)
        return PixelBubble.layout(text: text,detail: model.inMeeting ? "" : (model.detail.isEmpty ? "努力工作中" : model.detail),
            thinking: thinking,working: working,sprite: r,anchor: anchor,bounds: bounds,
            worldY: grid.snap(model.position.y),screenTop: model.visibleFrame.maxY,
            reserveTop: 0,grid: grid,ink: "2B1D1A",time: time)
    }

    private func drawBubble(above r: NSRect) {
        guard let layout = bubbleLayout(above: r), let context = NSGraphicsContext.current?.cgContext else { return }
        PixelBubble.draw(layout,text: time < model.speechUntil ? model.speech : "",
            detail: model.inMeeting ? "" : (model.detail.isEmpty ? "努力工作中" : model.detail),working: !model.inMeeting && model.state == .working,ink: "2B1D1A",in: context)
    }
}

final class PetController: NSObject, NSApplicationDelegate {
    var window: PetWindow!
    var petView: PetView!
    var model: PetModel!
    var screen: NSScreen?
    var timer: Timer?
    let frameGate = FrameGate()
    var reader: StateReader!
    var lastTick: TimeInterval = 0
    var nextPoll: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let initialScreen = NSScreen.main ?? NSScreen.screens.first else {
            fputs("DeskPet: no screen available.\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }
        screen = initialScreen
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/pet")
        let lines = SpeechLines(url: directory.appendingPathComponent("lines.json"))
        lines.reloadIfChanged()
        reader = StateReader(url: directory.appendingPathComponent("state.json"))
        let now = ProcessInfo.processInfo.systemUptime
        model = PetModel(frame: initialScreen.visibleFrame, lines: lines, now: now)
        model.meeting = MeetingCoordinator(directory: directory)
        petView = PetView(model: model)
        petView.time = now
        petView.controller = self
        window = PetWindow(contentRect: NSRect(origin: .zero, size: model.size.canvas),
                           styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "DeskPet"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = petView
        placeWindow()
        window.orderFrontRegardless()
        model.say(.idle, now: now)
        lastTick = now
        tick()
        schedule(1.0 / 60)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    func selectScreen(at point: NSPoint) {
        screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main ?? screen
        if let screen = screen { model.setScreen(screen.visibleFrame) }
    }

    @objc private func screensChanged() {
        guard model != nil else { return }
        selectScreen(at: NSPoint(x: model.position.x, y: model.position.y + 46 * model.size.scale))
    }

    func placeWindow() {
        let canvas = model.size.canvas
        if window.frame.size != canvas { window.setContentSize(canvas) }
        let grid = PixelGrid(cell: model.size.cell,backingScale: window.backingScaleFactor)
        let position = grid.point(model.position)
        let origin = model.meeting?.active?.interactionKind == .hide_seek
            ? grid.point(CGPoint(x: position.x-model.size.anchor.x,y: position.y-model.size.anchor.y))
            : model.size.windowOrigin(position: position,in: model.visibleFrame,backingScale: grid.backingScale)
        petView.anchor = grid.point(NSPoint(x: position.x-origin.x,y: position.y-origin.y))
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let animationTimer = Timer(timeInterval: interval, target: self, selector: #selector(tick),
                                   userInfo: nil, repeats: true)
        animationTimer.tolerance = interval / 10
        RunLoop.main.add(animationTimer, forMode: .common)
        timer = animationTimer
    }

    @objc func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1, max(0, now - lastTick))
        lastTick = now
        if now >= nextPoll {
            nextPoll = now + 0.5
            model.lines.reloadIfChanged()
            if let signal = reader.poll() { model.receive(signal, now: now) }
            if !model.dragging { screensChanged() }
        }
        model.step(dt: dt, now: now)
        model.tickUser(now: now)
        let body = petView.bodyRect
        let screenBody = body.isNull ? CGRect.null : window.convertToScreen(petView.convert(body, to: nil))
        model.user.updateCursor(NSEvent.mouseLocation,body: screenBody,mirrored: model.act.travel && model.direction < 0,
                                range: 150 * model.size.scale,blocked: model.userBusy || model.state == .sleeping,now: now)
        PixelSprite.eyeShift = model.user.eyeShift
        petView.time = now
        placeWindow()
        // Pass clicks through transparent areas; only sprite pixels capture the mouse.
        // Keep mouse capture for the duration of a drag, including outside its silhouette.
        let local = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let interactive = petView.holdingMouse || petView.containsCharacter(local)
        if window.ignoresMouseEvents == interactive { window.ignoresMouseEvents = !interactive }
        petView.frameGate = frameGate
        if let dirty = frameGate.changed(size: petView.bounds.size,scale: window.backingScaleFactor,draw: { petView.draw(petView.bounds,now: Date()) }) {
            petView.setNeedsDisplay(dirty)
        }
        let interval = FrameRate.interval(holding: petView.holdingMouse || model.dragging,
                                          airborne: !model.grounded || model.trick != nil || model.landing != nil || model.user.throwVX != 0,
                                          interacting: model.meeting?.active != nil || model.user.active(now) != nil,
                                          walking: model.meeting?.isWalking == true,strolling: model.walking,
                                          hovered: interactive,sleeping: model.state == .sleeping)
        if let t = timer, abs(t.timeInterval - interval) > 0.001 { schedule(interval) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        model?.meeting?.shutdown()
        NotificationCenter.default.removeObserver(self)
    }
}

// Entry point (the delegate is retained for the lifetime of the application).
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = PetController()
application.delegate = delegate
application.run()
