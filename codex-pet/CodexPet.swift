import AppKit

// Native pet scenes and integration. PixelDrawing.swift supplies the shared pixel renderer.
enum PetState: String, Codable, CaseIterable {
    case idle, thinking, working, done, error, sleeping
}

struct PetSignal: Decodable {
    let state: PetState
    let detail: String?
    let ts: Double?

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


struct LogMoodEvent {
    let timestamp: Date
    let state: PetState
    let detail: String
}
struct LogQuotaEvent {
    let timestamp: Date
    let quota: QuotaSnapshot
}
struct LogSnapshot {
    var event: LogMoodEvent?
    var quota: QuotaSnapshot?
    func signal(at now: Date) -> PetSignal {
        guard let event = event else { return .idle }
        let age = max(0,now.timeIntervalSince(event.timestamp))
        let state: PetState
        if event.state == .done {
            state = age < 6 ? .done : age < 186 ? .idle : .sleeping
        } else {
            state = age < 60 ? event.state : age < 240 ? .idle : .sleeping
        }
        return PetSignal(state: state,detail: state == event.state ? event.detail : "",ts: event.timestamp.timeIntervalSince1970)
    }
}

enum CodexLogParser {
    static func parse(_ data: Data) -> (LogMoodEvent?,LogQuotaEvent?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = object["timestamp"] as? String, let timestamp = LogDate.parse(stamp),
              let payload = object["payload"] as? [String: Any] else { return (nil,nil) }
        let rate = payload["rate_limits"] as? [String: Any]
            ?? (payload["info"] as? [String: Any])?["rate_limits"] as? [String: Any]
        let quota = rate.map { LogQuotaEvent(timestamp: timestamp,quota: QuotaSnapshot.codex($0)) }
        let type = object["type"] as? String, kind = payload["type"] as? String
        var state: PetState?, detail = ""
        if type == "event_msg" {
            if kind == "task_started" { state = .thinking }
            if kind == "task_complete" { state = .done }
        } else if type == "response_item" {
            switch kind {
            case "reasoning", "message": state = .thinking
            case "custom_tool_call", "function_call":
                state = .working; detail = toolDetail(payload)
            case "custom_tool_call_output", "function_call_output":
                // A successful output also clears a previous error: the tool chain is progressing.
                state = failed(payload) ? .error : .working
            default: break
            }
        }
        return (state.map { LogMoodEvent(timestamp: timestamp,state: $0,detail: detail) },quota)
    }
    static func toolDetail(_ payload: [String: Any]) -> String {
        let name = payload["name"] as? String ?? "tool"
        var input: Any? = payload["arguments"] ?? payload["input"]
        if let text = input as? String, let bytes = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: bytes) { input = parsed }
        if let fields = input as? [String: Any], let command = fields["cmd"] as? String ?? fields["command"] as? String,
           let first = command.split(whereSeparator: { $0.isWhitespace }).first { return String(first.prefix(60)) }
        return String(name.prefix(60))
    }
    static func failed(_ output: Any, depth: Int = 0) -> Bool {
        guard depth < 12 else { return false }
        if let fields = output as? [String: Any] {
            var hasExitCode = false
            for key in ["exit_code","exitCode","returncode"] {
                if let n = fields[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite {
                    hasExitCode = true
                    if n.doubleValue != 0 { return true }
                }
            }
            for key in ["isError","is_error"] {
                if let flag = fields[key] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue { return true }
            }
            if let status = fields["status"] as? String, ["failed","error"].contains(status.lowercased()) { return true }
            // An explicit successful shell result may print source code containing
            // "exit_code":1 or "Error:". Do not mistake that stdout for failure.
            if hasExitCode { return false }
            return ["output","content","text","result","value","structuredContent"].contains { key in
                fields[key].map { failed($0,depth: depth+1) } ?? false
            }
        }
        if let list = output as? [Any] { return list.contains { failed($0,depth: depth+1) } }
        guard let text = output as? String else { return false }
        if let data = text.data(using: .utf8),let json = try? JSONSerialization.jsonObject(with: data,options: .fragmentsAllowed),
           json is [String: Any] || json is [Any] { return failed(json,depth: depth+1) }
        let plain = text.replacingOccurrences(of: "\\n",with: "\n")
        let numeric = #"(?i)(?:\"(?:exit_code|exitCode|returncode)\"\s*:\s*|Process exited with code\s+|Exit code:\s*)(-?\d+)\b"#
        if let regex = try? NSRegularExpression(pattern: numeric) {
            let ns = plain as NSString
            for match in regex.matches(in: plain,range: NSRange(location: 0,length: ns.length)) {
                if let code = Int(ns.substring(with: match.range(at: 1))),code != 0 { return true }
            }
        }
        return false
    }
}

final class LogFileCache {
    let url: URL
    var stamp: FileStamp?
    var offset: UInt64 = 0
    var pending = Data()
    var event: LogMoodEvent?
    var quota: LogQuotaEvent?
    init(_ url: URL) { self.url = url }
    func poll() {
        guard let current = FileStamp.read(url), current != stamp else { return }
        if stamp?.inode != current.inode || current.size < offset || (current.size == offset && current != stamp) {
            offset = 0; pending.removeAll(); event = nil; quota = nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let bytes = try handle.readToEnd() ?? Data()
            offset += UInt64(bytes.count); pending.append(bytes); stamp = current
        } catch { return }
        var start = pending.startIndex
        for end in pending.indices where pending[end] == 10 {
            consume(Data(pending[start..<end])); start = pending.index(after: end)
        }
        if start > pending.startIndex { pending = Data(pending[start...]) }
        // Leave an incomplete final JSON line buffered until the writer appends its newline.
    }
    private func consume(_ data: Data) {
        let (newEvent,newQuota) = CodexLogParser.parse(data)
        if let e = newEvent, event == nil || e.timestamp >= event!.timestamp {
            let detail = e.detail.isEmpty && (e.state == .working || e.state == .error) ? (event?.detail ?? "") : e.detail
            event = LogMoodEvent(timestamp: e.timestamp,state: e.state,detail: detail)
        }
        if let q = newQuota, quota == nil || q.timestamp >= quota!.timestamp { quota = q }
    }
}

final class StateReader {
    let root: URL
    private var files: [String: LogFileCache] = [:]
    private var nextDiscovery = Date.distantPast
    init(root: URL) { self.root = root }
    func poll(at now: Date = Date()) -> LogSnapshot {
        if now >= nextDiscovery {
            nextDiscovery = now.addingTimeInterval(5)
            let keys: [URLResourceKey] = [.contentModificationDateKey,.isRegularFileKey]
            let enumerator = FileManager.default.enumerator(at: root,includingPropertiesForKeys: keys,options: [.skipsHiddenFiles])
            var candidates: [(URL,Date)] = []
            while let url = enumerator?.nextObject() as? URL {
                guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                candidates.append((url,values.contentModificationDate ?? .distantPast))
            }
            // Filename time protects new sessions from old files whose mtime was touched.
            // Also include recently modified files so a long-running, older session stays visible.
            let byName = candidates.sorted { $0.0.lastPathComponent > $1.0.lastPathComponent }.prefix(8)
            let byWrite = candidates.sorted { $0.1 > $1.1 }.prefix(8)
            let selected = Dictionary((Array(byName)+Array(byWrite)).map { ($0.0.path,$0.0) },uniquingKeysWith: { a,_ in a })
            files = selected.mapValues { files[$0.path] ?? LogFileCache($0) }
        }
        for file in files.values { file.poll() }
        // Choose by the actual event timestamp, never by file modification order.
        let event = files.values.compactMap(\.event).max { $0.timestamp < $1.timestamp }
        let quota = files.values.compactMap(\.quota).max { $0.timestamp < $1.timestamp }
        return LogSnapshot(event: event,quota: quota?.quota)
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
        "sleeping": ["呼……让我眯一会儿。", "梦里也在淋小雨。", "Zzz……小水滴还在哦。"],
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

enum PetSize: String, CaseIterable {
    case small, medium, large
    var cell: CGFloat { self == .small ? 4.5 : self == .medium ? 6 : 7.5 }
    // UI, window geometry and ground height stay on DeskPet's size scale.
    var uiCell: CGFloat { self == .small ? 6 : self == .medium ? 8 : 10 }
    var scale: CGFloat { uiCell / 6 }
    var title: String { self == .small ? "小" : self == .medium ? "中" : "大" }
    var canvas: NSSize { NSSize(width: 360 * scale, height: 360 * scale) }
    var anchor: NSPoint { PixelGrid(cell: uiCell).point(NSPoint(x: 180 * scale, y: 44 * scale)) }
    func windowOrigin(position: NSPoint, in frame: NSRect, backingScale: CGFloat = 2) -> NSPoint {
        let grid = PixelGrid(cell: uiCell,backingScale: backingScale)
        let position = grid.point(position)
        return grid.point(NSPoint(x: min(max(position.x - anchor.x, frame.minX), max(frame.minX, frame.maxX - canvas.width)),
                y: min(position.y - anchor.y, frame.maxY - canvas.height)))
    }
}

enum Outfit: String, CaseIterable {
    case none, duck, umbrella, goggles, bucket, ice, lotus, ring
    var title: String {
        switch self {
        case .none: return "素颜"
        case .duck: return "小黄鸭"
        case .umbrella: return "小雨伞"
        case .goggles: return "潜水镜"
        case .bucket: return "渔夫帽"
        case .ice: return "冰晶冠"
        case .lotus: return "荷叶帽"
        case .ring: return "游泳圈"
        }
    }
}

struct Act {
    let name: String
    var signature = ""
    var travel = false
    var walk = false
    static let all: [PetState: [Act]] = [
        .idle: [Act(name: "散步",travel: true,walk: true),Act(name: "挥手",walk: true)],
        .thinking: [Act(name: "认真想想")],
        .working: [Act(name: "敲键盘",walk: true)],
        .done: [Act(name: "欢呼撒彩纸")],
        .error: [Act(name: "晃动冒烟")],
        .sleeping: [Act(name: "化开打盹")]
    ]
    static let signatures: [PetState: [Act]] = [
        .idle: [Act(name: "淋小雨",signature: "rain",walk: true)],
        .working: [Act(name: "跑测试",signature: "test",walk: true)],
        .done: [Act(name: "溅水花",signature: "splash")]
    ]
}

enum Trick: String, CaseIterable {
    case jump, spin, hop2
    var duration: Double { self == .hop2 ? 0.8 : 0.6 }
    var steps: Int { self == .jump ? 3 : 4 }
}

// Column-vector affine math makes the SVG hierarchy identical for drawing and hit tests.


// BEGIN GENERATED DROP GEOMETRY
// Generated by generate_geometry.py from sketch_drop.py and sketch_base.py.
private enum DropGeometry {
    static func scene(mood: PetState,signature: String) -> ([PixelNode],[PixelNode]) {
        switch mood.rawValue + "|" + signature {
        case "idle|": return (idleInner,idleProps)
        case "thinking|": return (thinkingInner,thinkingProps)
        case "working|": return (workingInner,workingProps)
        case "done|": return (doneInner,doneProps)
        case "error|": return (errorInner,errorProps)
        case "sleeping|": return (sleepingInner,sleepingProps)
        case "working|test": return (workingTestInner,workingTestProps)
        case "idle|rain": return (idleRainInner,idleRainProps)
        case "done|splash": return (doneSplashInner,doneSplashProps)
        default: return scene(mood: mood,signature: "")
        }
    }
    private static let idleInner: [PixelNode] = [
        .rect(CGRect(x: 11.5,y: 0,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 1,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 12.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 13.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 3),"FFFFFF",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"FFFFFF",""),
        .rect(CGRect(x: 13.5,y: 5,width: 2,height: 1),"A6DDFB",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 2),"A6DDFB",""),
        .group("blink",[
            .rect(CGRect(x: 9.1,y: 8,width: 0.5,height: 1),"1E2A44",""),
            .rect(CGRect(x: 14.1,y: 8,width: 0.5,height: 1),"1E2A44","")
        ]),
        .rect(CGRect(x: 7.1,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 15.7,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 11.5,y: 9.4,width: 1,height: 0.3),"1E2A44",""),
        .rect(CGRect(x: 10.9,y: 11.3,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 11.3,y: 11.7,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 10.9,y: 12.1,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 12.1,y: 12.2,width: 1,height: 0.3),"2F6FB8",""),
        .group("wave",[
            .rect(CGRect(x: 3.7,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .group("",[
            .rect(CGRect(x: 19.1,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .rect(CGRect(x: 8.5,y: 14,width: 2,height: 0.9),"2F6FB8","legA"),
        .rect(CGRect(x: 13.5,y: 14,width: 2,height: 0.9),"2F6FB8","legB")
    ]
    private static let idleProps: [PixelNode] = [

    ]
    private static let thinkingInner: [PixelNode] = [
        .rect(CGRect(x: 11.5,y: 0,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 1,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 12.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 13.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 3),"FFFFFF",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"FFFFFF",""),
        .rect(CGRect(x: 13.5,y: 5,width: 2,height: 1),"A6DDFB",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 2),"A6DDFB",""),
        .group("blink",[
            .rect(CGRect(x: 9.1,y: 7.4,width: 0.5,height: 1),"1E2A44",""),
            .rect(CGRect(x: 14.1,y: 7.4,width: 0.5,height: 1),"1E2A44","")
        ]),
        .rect(CGRect(x: 7.1,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 15.7,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 11.5,y: 9.4,width: 1,height: 0.3),"1E2A44",""),
        .rect(CGRect(x: 10.9,y: 11.3,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 11.3,y: 11.7,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 10.9,y: 12.1,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 12.1,y: 12.2,width: 1,height: 0.3),"2F6FB8",""),
        .group("",[
            .rect(CGRect(x: 3.7,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .group("",[
            .rect(CGRect(x: 19.1,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .rect(CGRect(x: 8.5,y: 14,width: 2,height: 0.9),"2F6FB8",""),
        .rect(CGRect(x: 13.5,y: 14,width: 2,height: 0.9),"2F6FB8","")
    ]
    private static let thinkingProps: [PixelNode] = [
        .group("bubble",[
            .rect(CGRect(x: 17.5,y: -1.6,width: 3.4,height: 2.8),"9A8A84",""),
            .rect(CGRect(x: 17.6,y: -1.5,width: 3.2,height: 2.6),"FFFFFF",""),
            .rect(CGRect(x: 18.5,y: -1,width: 1.4,height: 0.4),"1E2A44",""),
            .rect(CGRect(x: 19.5,y: -0.6,width: 0.4,height: 0.6),"1E2A44",""),
            .rect(CGRect(x: 18.9,y: 0.2,width: 0.5,height: 0.4),"1E2A44","")
        ])
    ]
    private static let workingInner: [PixelNode] = [
        .rect(CGRect(x: 11.5,y: 0,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 1,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 12.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 13.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 3),"FFFFFF",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"FFFFFF",""),
        .rect(CGRect(x: 13.5,y: 5,width: 2,height: 1),"A6DDFB",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 2),"A6DDFB",""),
        .group("blink",[
            .rect(CGRect(x: 9.1,y: 8.4,width: 0.5,height: 1),"1E2A44",""),
            .rect(CGRect(x: 14.1,y: 8.4,width: 0.5,height: 1),"1E2A44","")
        ]),
        .rect(CGRect(x: 7.1,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 15.7,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 11.5,y: 9.3,width: 1,height: 0.5),"1E2A44",""),
        .rect(CGRect(x: 10.9,y: 11.3,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 11.3,y: 11.7,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 10.9,y: 12.1,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 12.1,y: 12.2,width: 1,height: 0.3),"2F6FB8",""),
        .group("typeL",[
            .rect(CGRect(x: 3.7,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .group("typeR",[
            .rect(CGRect(x: 19.1,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .rect(CGRect(x: 8.5,y: 14,width: 2,height: 0.9),"2F6FB8","legA"),
        .rect(CGRect(x: 13.5,y: 14,width: 2,height: 0.9),"2F6FB8","legB")
    ]
    private static let workingProps: [PixelNode] = [
        .rect(CGRect(x: 3.5,y: 12.4,width: 17,height: 1.2),"C9D2F5",""),
        .rect(CGRect(x: 4.1,y: 12.6,width: 1.2,height: 0.6),"FFFFFF","keyp k0"),
        .rect(CGRect(x: 6.1,y: 12.6,width: 1.2,height: 0.6),"FFFFFF","keyp k1"),
        .rect(CGRect(x: 8.1,y: 12.6,width: 1.2,height: 0.6),"FFFFFF","keyp k2"),
        .rect(CGRect(x: 10.1,y: 12.6,width: 1.2,height: 0.6),"FFFFFF","keyp k0"),
        .rect(CGRect(x: 12.1,y: 12.6,width: 1.2,height: 0.6),"FFFFFF","keyp k1"),
        .rect(CGRect(x: 14.1,y: 12.6,width: 1.2,height: 0.6),"FFFFFF","keyp k2"),
        .rect(CGRect(x: 16.1,y: 12.6,width: 1.2,height: 0.6),"FFFFFF","keyp k0"),
        .rect(CGRect(x: 18.1,y: 12.6,width: 1.2,height: 0.6),"FFFFFF","keyp k1")
    ]
    private static let doneInner: [PixelNode] = [
        .rect(CGRect(x: 11.5,y: 0,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 1,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 12.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 13.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 3),"FFFFFF",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"FFFFFF",""),
        .rect(CGRect(x: 13.5,y: 5,width: 2,height: 1),"A6DDFB",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 2),"A6DDFB",""),
        .rect(CGRect(x: 8.7,y: 8.4,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 9.1,y: 8,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 9.5,y: 8.4,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 13.7,y: 8.4,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 14.1,y: 8,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 14.5,y: 8.4,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 7.1,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 15.7,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 11.1,y: 9.2,width: 1.8,height: 0.6),"1E2A44",""),
        .rect(CGRect(x: 10.9,y: 11.3,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 11.3,y: 11.7,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 10.9,y: 12.1,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 12.1,y: 12.2,width: 1,height: 0.3),"2F6FB8",""),
        .group("up",[
            .rect(CGRect(x: 3.7,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .group("up",[
            .rect(CGRect(x: 19.1,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .rect(CGRect(x: 8.5,y: 14,width: 2,height: 0.9),"2F6FB8",""),
        .rect(CGRect(x: 13.5,y: 14,width: 2,height: 0.9),"2F6FB8","")
    ]
    private static let doneProps: [PixelNode] = [
        .rect(CGRect(x: 2.5,y: 2,width: 0.6,height: 0.6),"F2C14E","confetti c0"),
        .rect(CGRect(x: 5.5,y: -1,width: 0.6,height: 0.6),"5BD38A","confetti c1"),
        .rect(CGRect(x: 17.5,y: -1,width: 0.6,height: 0.6),"F2C14E","confetti c2"),
        .rect(CGRect(x: 20.5,y: 3,width: 0.6,height: 0.6),"5BD38A","confetti c0")
    ]
    private static let errorInner: [PixelNode] = [
        .rect(CGRect(x: 11.5,y: 0,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 1,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 12.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 13.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 3),"FFFFFF",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"FFFFFF",""),
        .rect(CGRect(x: 13.5,y: 5,width: 2,height: 1),"A6DDFB",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 2),"A6DDFB",""),
        .rect(CGRect(x: 8.7,y: 8,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 9.5,y: 8,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 9.1,y: 8.4,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 8.7,y: 8.8,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 9.5,y: 8.8,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 13.7,y: 8,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 14.5,y: 8,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 14.1,y: 8.4,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 13.7,y: 8.8,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 14.5,y: 8.8,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 7.1,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 15.7,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 11.3,y: 9.6,width: 1.4,height: 0.3),"1E2A44",""),
        .rect(CGRect(x: 10.9,y: 11.3,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 11.3,y: 11.7,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 10.9,y: 12.1,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 12.1,y: 12.2,width: 1,height: 0.3),"2F6FB8",""),
        .group("flail",[
            .rect(CGRect(x: 3.7,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .group("flail",[
            .rect(CGRect(x: 19.1,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .rect(CGRect(x: 8.5,y: 14,width: 2,height: 0.9),"2F6FB8",""),
        .rect(CGRect(x: 13.5,y: 14,width: 2,height: 0.9),"2F6FB8","")
    ]
    private static let errorProps: [PixelNode] = [
        .group("smoke",[
            .rect(CGRect(x: 16.5,y: -1.5,width: 1.4,height: 1.2),"C9C9C9",""),
            .rect(CGRect(x: 17.7,y: -2.7,width: 1,height: 1),"DDDDDD","")
        ])
    ]
    private static let sleepingInner: [PixelNode] = [
        .rect(CGRect(x: 11.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 12.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 13.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 5,width: 1,height: 3),"FFFFFF",""),
        .rect(CGRect(x: 9.5,y: 4,width: 1,height: 1),"FFFFFF",""),
        .rect(CGRect(x: 13.5,y: 6,width: 2,height: 1),"A6DDFB",""),
        .rect(CGRect(x: 14.5,y: 7,width: 1,height: 2),"A6DDFB",""),
        .rect(CGRect(x: 8.7,y: 8.6,width: 1.2,height: 0.3),"1E2A44",""),
        .rect(CGRect(x: 13.7,y: 8.6,width: 1.2,height: 0.3),"1E2A44",""),
        .rect(CGRect(x: 7.1,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 15.7,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 11.5,y: 9.4,width: 1,height: 0.3),"1E2A44",""),
        .rect(CGRect(x: 10.9,y: 11.3,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 11.3,y: 11.7,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 10.9,y: 12.1,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 12.1,y: 12.2,width: 1,height: 0.3),"2F6FB8",""),
        .group("droop",[
            .rect(CGRect(x: 3.7,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .group("droop",[
            .rect(CGRect(x: 19.1,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .rect(CGRect(x: 8.5,y: 14,width: 2,height: 0.9),"2F6FB8",""),
        .rect(CGRect(x: 13.5,y: 14,width: 2,height: 0.9),"2F6FB8","")
    ]
    private static let sleepingProps: [PixelNode] = [
        .group("z",[
            .rect(CGRect(x: 18.5,y: 1,width: 1.4,height: 0.4),"1E2A44",""),
            .rect(CGRect(x: 19,y: 1.4,width: 0.5,height: 0.5),"1E2A44",""),
            .rect(CGRect(x: 18.5,y: 1.9,width: 1.4,height: 0.4),"1E2A44","")
        ])
    ]
    private static let workingTestInner: [PixelNode] = [
        .rect(CGRect(x: 11.5,y: 0,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 1,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 12.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 13.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 3),"FFFFFF",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"FFFFFF",""),
        .rect(CGRect(x: 13.5,y: 5,width: 2,height: 1),"A6DDFB",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 2),"A6DDFB",""),
        .group("blink",[
            .rect(CGRect(x: 9.1,y: 8.4,width: 0.5,height: 1),"1E2A44",""),
            .rect(CGRect(x: 14.1,y: 8.4,width: 0.5,height: 1),"1E2A44","")
        ]),
        .rect(CGRect(x: 7.1,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 15.7,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 11.5,y: 9.3,width: 1,height: 0.5),"1E2A44",""),
        .rect(CGRect(x: 10.9,y: 11.3,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 11.3,y: 11.7,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 10.9,y: 12.1,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 12.1,y: 12.2,width: 1,height: 0.3),"2F6FB8",""),
        .group("reach",[
            .rect(CGRect(x: 3.7,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .group("reach",[
            .rect(CGRect(x: 19.1,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .rect(CGRect(x: 8.5,y: 14,width: 2,height: 0.9),"2F6FB8","legA"),
        .rect(CGRect(x: 13.5,y: 14,width: 2,height: 0.9),"2F6FB8","legB")
    ]
    private static let workingTestProps: [PixelNode] = [
        .rect(CGRect(x: 3.5,y: -3.4,width: 17,height: 1.8),"18203A",""),
        .rect(CGRect(x: 3.8,y: -3.1,width: 16.4,height: 1.2),"2A3352",""),
        .rect(CGRect(x: 3.8,y: -3.1,width: 16.4,height: 1.2),"5BD38A","bar")
    ]
    private static let idleRainInner: [PixelNode] = [
        .rect(CGRect(x: 11.5,y: 0,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 1,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 12.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 13.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 3),"FFFFFF",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"FFFFFF",""),
        .rect(CGRect(x: 13.5,y: 5,width: 2,height: 1),"A6DDFB",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 2),"A6DDFB",""),
        .group("blink",[
            .rect(CGRect(x: 9.1,y: 7.4,width: 0.5,height: 1),"1E2A44",""),
            .rect(CGRect(x: 14.1,y: 7.4,width: 0.5,height: 1),"1E2A44","")
        ]),
        .rect(CGRect(x: 7.1,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 15.7,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 11.5,y: 9.4,width: 1,height: 0.3),"1E2A44",""),
        .rect(CGRect(x: 10.9,y: 11.3,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 11.3,y: 11.7,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 10.9,y: 12.1,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 12.1,y: 12.2,width: 1,height: 0.3),"2F6FB8",""),
        .group("wave",[
            .rect(CGRect(x: 3.7,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .group("",[
            .rect(CGRect(x: 19.1,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .rect(CGRect(x: 8.5,y: 14,width: 2,height: 0.9),"2F6FB8","legA"),
        .rect(CGRect(x: 13.5,y: 14,width: 2,height: 0.9),"2F6FB8","legB")
    ]
    private static let idleRainProps: [PixelNode] = [
        .rect(CGRect(x: 7.5,y: -4,width: 9,height: 2),"DDE6EE",""),
        .rect(CGRect(x: 9,y: -5,width: 5,height: 1.2),"DDE6EE",""),
        .rect(CGRect(x: 8.5,y: -1.6,width: 0.3,height: 0.7),"3A8FD6","rain r0"),
        .rect(CGRect(x: 10.5,y: -1.6,width: 0.3,height: 0.7),"3A8FD6","rain r1"),
        .rect(CGRect(x: 12.5,y: -1.6,width: 0.3,height: 0.7),"3A8FD6","rain r0"),
        .rect(CGRect(x: 14.5,y: -1.6,width: 0.3,height: 0.7),"3A8FD6","rain r1")
    ]
    private static let doneSplashInner: [PixelNode] = [
        .rect(CGRect(x: 11.5,y: 0,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 1,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 1,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 2,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 2,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 3,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 3,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 4,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 4,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 5,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 5,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 6,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 6,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 7,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 7,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 8,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 8,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 9,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 9,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 5.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 7.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 10,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 17.5,y: 10,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 6.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 8.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 11,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 16.5,y: 11,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 7.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 9.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 10.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 11.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 12.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 13.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 14.5,y: 12,width: 1,height: 1),"6CC4F5",""),
        .rect(CGRect(x: 15.5,y: 12,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 9.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 10.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 11.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 12.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 13.5,y: 13,width: 1,height: 1),"3A8FD6",""),
        .rect(CGRect(x: 8.5,y: 4,width: 1,height: 3),"FFFFFF",""),
        .rect(CGRect(x: 9.5,y: 3,width: 1,height: 1),"FFFFFF",""),
        .rect(CGRect(x: 13.5,y: 5,width: 2,height: 1),"A6DDFB",""),
        .rect(CGRect(x: 14.5,y: 6,width: 1,height: 2),"A6DDFB",""),
        .rect(CGRect(x: 8.7,y: 8.4,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 9.1,y: 8,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 9.5,y: 8.4,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 13.7,y: 8.4,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 14.1,y: 8,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 14.5,y: 8.4,width: 0.4,height: 0.4),"1E2A44",""),
        .rect(CGRect(x: 7.1,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 15.7,y: 9.3,width: 1.2,height: 0.5),"F7A6B8",""),
        .rect(CGRect(x: 11.1,y: 9.2,width: 1.8,height: 0.6),"1E2A44",""),
        .rect(CGRect(x: 10.9,y: 11.3,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 11.3,y: 11.7,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 10.9,y: 12.1,width: 0.4,height: 0.4),"2F6FB8",""),
        .rect(CGRect(x: 12.1,y: 12.2,width: 1,height: 0.3),"2F6FB8",""),
        .group("up",[
            .rect(CGRect(x: 3.7,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .group("up",[
            .rect(CGRect(x: 19.1,y: 9,width: 1.2,height: 0.8),"3A8FD6","")
        ]),
        .rect(CGRect(x: 8.5,y: 14,width: 2,height: 0.9),"2F6FB8",""),
        .rect(CGRect(x: 13.5,y: 14,width: 2,height: 0.9),"2F6FB8","")
    ]
    private static let doneSplashProps: [PixelNode] = [
        .rect(CGRect(x: 2.5,y: 4,width: 0.6,height: 0.8),"6CC4F5","confetti c0"),
        .rect(CGRect(x: 4.5,y: 1,width: 0.6,height: 0.8),"6CC4F5","confetti c1"),
        .rect(CGRect(x: 18.5,y: 1,width: 0.6,height: 0.8),"6CC4F5","confetti c2"),
        .rect(CGRect(x: 20.5,y: 4,width: 0.6,height: 0.8),"6CC4F5","confetti c0"),
        .rect(CGRect(x: 11.5,y: -2,width: 0.6,height: 0.8),"6CC4F5","confetti c1")
    ]
}
private enum DropOutfitGeometry {
    static func nodes(_ outfit: Outfit) -> [PixelNode] {
        switch outfit {
        case .none: return [

        ]
        case .duck: return [
            .rect(CGRect(x: 9.1,y: -1.6,width: 5.4,height: 2),"F7D33C",""),
            .rect(CGRect(x: 12.7,y: -3.4,width: 2.8,height: 2),"F7D33C",""),
            .rect(CGRect(x: 15.5,y: -2.8,width: 1.2,height: 0.7),"F29B38",""),
            .rect(CGRect(x: 14.3,y: -2.9,width: 0.5,height: 0.5),"1E2A44",""),
            .rect(CGRect(x: 8.7,y: -1.2,width: 0.8,height: 0.8),"F7D33C","")
        ]
        case .umbrella: return [
            .rect(CGRect(x: 8,y: -4.2,width: 8,height: 1),"E85D75",""),
            .rect(CGRect(x: 7,y: -3.2,width: 10,height: 1),"E85D75",""),
            .rect(CGRect(x: 10,y: -3.2,width: 1,height: 1),"FFFFFF",""),
            .rect(CGRect(x: 14,y: -3.2,width: 1,height: 1),"FFFFFF",""),
            .rect(CGRect(x: 12,y: -4.2,width: 1,height: 1),"FFFFFF",""),
            .rect(CGRect(x: 11.8,y: -2.2,width: 0.4,height: 2.4),"3C4043",""),
            .rect(CGRect(x: 11.6,y: -5,width: 0.8,height: 0.8),"3C4043","")
        ]
        case .goggles: return [
            .rect(CGRect(x: 5.7,y: 7.6,width: 12.6,height: 0.5),"2F6FB8",""),
            .rect(CGRect(x: 8.1,y: 7,width: 2.4,height: 2),"1E2A44",""),
            .rect(CGRect(x: 8.3,y: 7.2,width: 2,height: 1.6),"BFEFFF",""),
            .rect(CGRect(x: 13.5,y: 7,width: 2.4,height: 2),"1E2A44",""),
            .rect(CGRect(x: 13.7,y: 7.2,width: 2,height: 1.6),"BFEFFF",""),
            .rect(CGRect(x: 10.5,y: 7.6,width: 3,height: 0.4),"1E2A44",""),
            .rect(CGRect(x: 9.1,y: 7.6,width: 0.5,height: 0.9),"1E2A44",""),
            .rect(CGRect(x: 14.4,y: 7.6,width: 0.5,height: 0.9),"1E2A44","")
        ]
        case .bucket: return [
            .rect(CGRect(x: 7.1,y: -0.2,width: 9.8,height: 0.8),"C8A86B",""),
            .rect(CGRect(x: 8.7,y: -2,width: 6.6,height: 1.8),"D9BC7E",""),
            .rect(CGRect(x: 8.7,y: -0.8,width: 6.6,height: 0.5),"8B6B3D","")
        ]
        case .ice: return [
            .rect(CGRect(x: 9,y: -1,width: 6,height: 1),"8FD3F5",""),
            .rect(CGRect(x: 9,y: -2,width: 1,height: 1),"8FD3F5",""),
            .rect(CGRect(x: 11.5,y: -2.8,width: 1,height: 1.8),"B9E6FA",""),
            .rect(CGRect(x: 14,y: -2,width: 1,height: 1),"8FD3F5",""),
            .rect(CGRect(x: 11.6,y: -0.8,width: 0.8,height: 0.6),"3A8FD6","")
        ]
        case .lotus: return [
            .rect(CGRect(x: 6.5,y: -0.6,width: 11,height: 0.8),"5BAA5B",""),
            .rect(CGRect(x: 7.5,y: -1.2,width: 9,height: 0.6),"76C176",""),
            .rect(CGRect(x: 11.7,y: -2.6,width: 0.4,height: 1.4),"3E8E3E",""),
            .rect(CGRect(x: 11.3,y: -3.8,width: 1.2,height: 1.2),"F7A6B8",""),
            .rect(CGRect(x: 11.5,y: -4.4,width: 0.8,height: 0.6),"F27E9C","")
        ]
        case .ring: return [
            .rect(CGRect(x: 4.1,y: 10.4,width: 15.8,height: 1.8),"F06A5A",""),
            .rect(CGRect(x: 5.7,y: 10.4,width: 1.4,height: 1.8),"FFFFFF",""),
            .rect(CGRect(x: 11.3,y: 10.4,width: 1.4,height: 1.8),"FFFFFF",""),
            .rect(CGRect(x: 16.9,y: 10.4,width: 1.4,height: 1.8),"FFFFFF","")
        ]
        }
    }
}
// END GENERATED DROP GEOMETRY

// A direct port of STYLE + EXTRA: CSS px / 10 gives cell-space distances.
enum PixelMotion {
    static func sample(_ frames: [(Double, CGFloat)], phase: Double, steps: Int) -> CGFloat {
        if phase <= frames[0].0 { return frames[0].1 }
        for i in 1..<frames.count where phase < frames[i].0 {
            let left = frames[i-1], right = frames[i]
            let p = floor((phase-left.0)/(right.0-left.0)*Double(steps))/Double(steps)
            return left.1+(right.1-left.1)*CGFloat(p)
        }
        return frames.last!.1
    }
    fileprivate static func pose(_ name: String,time: Double,duration: Double = 1,steps: Int = 1,
                                 delay: Double = 0,once: Bool = false) -> Pose {
        guard time >= delay else { return Pose(opacity: ["rise","fall","drip"].contains(name) ? 0 : 1) }
        let elapsed = max(0,time-delay)/duration
        let p = once ? min(1,elapsed) : elapsed.truncatingRemainder(dividingBy: 1)
        func v(_ f: [(Double,CGFloat)]) -> CGFloat { sample(f,phase: p,steps: steps) }
        func on(_ f: [(Double,CGFloat)]) -> CGFloat { sample(f,phase: p,steps: 1) }
        var result = Pose()
        switch name {
        case "bob": result.y = v([(0,0),(0.5,-0.4),(1,0)])
        case "jump": result.y = v([(0,0),(0.5,-2),(1,0)])
        case "shake": result.x = v([(0,-0.4),(0.5,0.4),(1,-0.4)])
        case "blink": result.opacity = on([(0,1),(0.49,1),(0.5,0),(1,0)])
        case "blink2": result.opacity = on([(0,1),(0.93,1),(0.95,0),(1,0)])
        case "wave": result.y = v([(0,0),(0.6,0),(0.65,-2),(0.7,-1),(0.75,-2),(0.8,-1),(1,0)])
        case "flail": result.y = v([(0,-1),(0.5,0.5),(1,-1)])
        case "tap": result.y = v([(0,0),(0.5,0.3),(1,0)])
        case "bar": break // The progress strip is drawn at discrete widths, never scaled.
        case "fall": result.y = v([(0,0),(1,4)]);result.opacity = on([(0,1),(0.91,0),(1,0)])
        case "rise":
            result.y = v([(0,0.6),(1,-1.4)])
            result.opacity = on([(0,0),(0.10,1),(0.91,0),(1,0)])
        case "drip": result.y = v([(0,0),(1,1.4)]);result.opacity = on([(0,1),(0.91,0),(1,0)])
        case "spin": result.mirrored = Int(p*4)%2 == 1
        case "hop2": result.y = v([(0,0),(0.25,-1.4),(0.5,0),(0.75,-1.4),(1,0)])
        default: break
        }
        result.x = (result.x*2).rounded()/2
        result.y = (result.y*2).rounded()/2
        return result
    }
    static func progressWidth(_ width: CGFloat, time: Double) -> CGFloat {
        let phase = max(0,time).truncatingRemainder(dividingBy: 3)/3
        let fraction = 0.05+0.95*CGFloat(floor(phase*10)/10)
        return max(0.5,(width*fraction*2).rounded()/2)
    }
}

final class PixelSprite {
    // Set each tick from the cursor (Task 13); shifts open eyes by one whole step.
    static var eyeShift = CGPoint.zero
    static let cell: CGFloat = 5.5
    private static func motion(_ cls: String,time: Double,walking: Bool) -> Pose {
        let words = cls.split(separator: " ").map(String.init)
        func a(_ name: String,_ duration: Double,_ steps: Int = 1,_ delay: Double = 0) -> Pose {
            PixelMotion.pose(name,time: time,duration: duration,steps: steps,delay: delay)
        }
        switch words.first ?? "" {
        case "blink": var p = a("blink2",3.6); p.x += eyeShift.x; p.y += eyeShift.y; return p
        case "wave": return a("wave",3)
        case "up": return Pose(y: -1.6)
        case "reach": return Pose(y: -3)
        case "droop": return Pose(y: 0.6)
        case "flail": return a("flail",0.3)
        case "typeL": return a("tap",0.25)
        case "typeR": return a("tap",0.25,1,0.12)
        case "legA": return walking ? a("tap",0.5) : Pose()
        case "legB": return walking ? a("tap",0.5,1,0.25) : Pose()
        case "keyp": return a("blink",0.5,1,words.contains("k1") ? 0.15 : words.contains("k2") ? 0.3 : 0)
        case "bar": return a("bar",3,10)
        case "confetti": return a("fall",1.2,6,words.contains("c1") ? 0.4 : words.contains("c2") ? 0.8 : 0)
        case "smoke", "z": return a("rise",1.6,4)
        case "rain": return a("drip",0.6,3,words.contains("r1") ? 0.3 : 0)
        default: return Pose() // .bubble has no animation in the source CSS.
        }
    }
    static func primitives(mood: PetState,act: Act,elapsed: Double,anchor: CGPoint,
                           mirrored: Bool,walking: Bool,trick: Trick? = nil,trickTime: Double = 0,
                           squash: CGFloat = 0,pixelScale: CGFloat = 2,cell: CGFloat = PixelSprite.cell,meeting: Bool = false,outfit: Outfit = .none) -> [PixelPrimitive] {
        let (rawInner,rawProps) = DropGeometry.scene(mood: mood,signature: meeting ? "" : act.signature)
        let inner = meeting ? rawInner.filter { node in
            if case .group(let cls,_) = node { return !["wave","up","reach","droop","flail","typeL","typeR"].contains(cls) };return true
        } : rawInner
        let props = meeting ? [] : rawProps
        let grid = PixelGrid(cell: cell,backingScale: pixelScale)
        // The window's UI grid sets the ground line; don't re-snap it to the drop's smaller grid.
        let anchor = CGPoint(x: grid.pixel(anchor.x),y: grid.pixel(anchor.y))
        let base = PixelTransform(a: cell,d: -cell,tx: grid.pixel(anchor.x-12*cell),ty: grid.pixel(anchor.y+14.9*cell))
        let facing = mirrored ? PixelTransform.translate(24,0).times(.mirror) : PixelTransform()
        let world = base.times(facing)
        let duration: Double = mood == .working ? 0.5 : mood == .done ? 0.8 : mood == .error ? 0.3 : mood == .sleeping ? 3 : 1.6
        var body = PixelMotion.pose(mood == .done ? "jump" : mood == .error ? "shake" : "bob",time: elapsed,
                                    duration: duration,steps: mood == .done ? 4 : 2)
        if meeting { body = Pose() }
        if let trick = trick,trickTime < trick.duration {
            body = PixelMotion.pose(trick.rawValue,time: trickTime,duration: trick.duration,steps: trick.steps,once: true)
        }
        var pet = world.times(body.transform(around: CGPoint(x: 12,y: 14.9),grid: grid))
        // Landing is a one-unit bob, never a scale transform.
        if squash > 0 { pet = pet.times(Pose(y: 0.5).transform(around: .zero,grid: grid)) }
        var result: [PixelPrimitive] = []
        func visit(_ node: PixelNode,parent: PixelTransform,opacity: CGFloat,interactive: Bool) {
            let cls: String
            switch node { case .rect(_,_,let c): cls = c;case .group(let c,_): cls = c }
            let pose = motion(cls,time: elapsed,walking: walking)
            let alpha = opacity*pose.opacity
            precondition(alpha == 0 || alpha == 1)
            guard alpha == 1 else { return }
            let pivot = cls == "bar" ? CGPoint(x: node.bounds.minX,y: node.bounds.midY) : .zero
            let transform = parent.times(pose.transform(around: pivot,grid: grid))
            switch node {
            case .group(_,let children):
                for child in children { visit(child,parent: transform,opacity: alpha,interactive: interactive) }
            case .rect(let rect,let hex,_):
                var rect = rect
                if cls == "bar" { rect.size.width = PixelMotion.progressWidth(rect.width,time: elapsed) }
                if let primitive = PixelPrimitive.transformed(rect,by: transform,grid: grid,hex: hex,interactive: interactive) {
                    result.append(primitive)
                }
            }
        }
        for node in inner { visit(node,parent: pet,opacity: 1,interactive: true) }
        // The approved outfit is the last body layer: goggles cover the face, the ring covers limbs.
        // Sleeping removes a body row and lowers its tip by one cell; lower the outfit with it.
        let outfitTransform = mood == .sleeping ? pet.times(.translate(0,1)) : pet
        for node in DropOutfitGeometry.nodes(outfit) { visit(node,parent: outfitTransform,opacity: 1,interactive: true) }
        for node in props { visit(node,parent: pet,opacity: 1,interactive: false) }
        return result
    }
    static func draw(_ primitives: [PixelPrimitive],in context: CGContext) {
        context.saveGState();PixelDrawing.crisp(context)
        for primitive in primitives { context.setFillColor(primitive.color);context.fill(primitive.rect) }
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
    var stateSince: TimeInterval
    var idleSince: TimeInterval
    var position: NSPoint
    var visibleFrame: NSRect
    var direction: CGFloat = 1
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
    var quota: QuotaSnapshot?
    private var lastSignalTimestamp: Double?
    private(set) var outfit: Outfit
    private(set) var size: PetSize
    var availableActs: [Act] { Act.all[state]! + (Act.signatures[state] ?? []) }
    var act: Act { availableActs[actIndex % availableActs.count] }
    var nextPause: TimeInterval
    var pauseUntil: TimeInterval = 0
    var speech = ""
    var speechUntil: TimeInterval = 0
    let lines: SpeechLines

    var floor: CGFloat { visibleFrame.minY + QuotaBattery.groundHeight(cell: size.uiCell) }
    // Sprite and hat margin; the quota plate is centred underneath.
    var edgeInset: CGFloat { min(13 * size.cell, visibleFrame.width / 2) }
    var grounded: Bool { position.y <= floor + 0.5 && velocityY == 0 }
    var walking: Bool { meeting?.controlsMotion != true && !quiet && !dragging && grounded && act.travel && trick == nil && landing == nil && !user.blocksWalk }
    var moving: Bool { walking && (state != .idle || clock >= pauseUntil) }
    private var clock: TimeInterval = 0

    init(frame: NSRect, lines: SpeechLines, now: TimeInterval, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        outfit = preferences.string(forKey: "outfit").flatMap(Outfit.init(rawValue:)) ?? .none
        size = preferences.string(forKey: "size").flatMap(PetSize.init(rawValue:)) ?? .medium
        actSince = now
        nextAct = now + 9
        clock = now
        self.lines = lines
        visibleFrame = frame
        position = NSPoint(x: frame.minX + min(150 * size.scale, frame.width / 2), y: frame.minY + QuotaBattery.groundHeight(cell: size.uiCell))
        stateSince = now
        idleSince = now
        nextPause = now + 5
        chooseAct(now: now, avoidingCurrent: false)
    }

    func chooseOutfit(_ outfit: Outfit) {
        self.outfit = outfit
        preferences.set(outfit.rawValue,forKey: "outfit")
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
        let signatureCount = (Act.signatures[state] ?? []).count
        // Choose a signature act about half the time, when one fits the mood.
        let pool = signatureCount > 0 && Bool.random() ? Array(count..<(count + signatureCount)) : Array(0..<count)
        let choices = avoidingCurrent && pool.count > 1 ? pool.filter { $0 != actIndex } : pool
        // A one-act signature pool may repeat; keep the 50/50 weighting.
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
        detail = String((signal.detail ?? "").prefix(80))
        guard signal.state != externalState || signal.ts != lastSignalTimestamp else { return }
        externalState = signal.state
        lastSignalTimestamp = signal.ts
        if signal.state == .idle { idleSince = now }
        if signal.state == .done { stateSince = now }
        transition(to: signal.state,now: now)
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
        position.y = min(max(position.y, floor), max(floor, visibleFrame.maxY - 134 * size.scale))
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
        setAccessibilityLabel("小水滴桌宠；点击打招呼，拖动移动，右键打开菜单")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isOpaque: Bool { false }
    var holdingMouse: Bool { mouseOrigin != nil }

    var sprite: [PixelPrimitive] {
        if let pixels = landingSprite { return pixels }
        if let pixels = meetingSprite { return pixels }
        return PixelSprite.primitives(mood: model.state, act: model.act,
                               elapsed: max(0,time-model.actSince), anchor: NSPoint(x: anchor.x+model.user.wobble(now: time,unit: model.size.uiCell/2),y: anchor.y),
                               mirrored: (model.act.travel && model.direction < 0) != model.user.mirror(now: time),
                               walking: model.act.walk && (!model.act.travel || model.moving),
                               trick: model.trick, trickTime: max(0,time-model.trickSince),
                               squash: model.landingSquash, pixelScale: window?.backingScaleFactor ?? 2,
                               cell: model.size.cell,outfit: model.outfit)
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
        let find = NSMenuItem(title: "去找小橘",action: #selector(findFriend),keyEquivalent: "")
        find.target = self;menu.addItem(find)
        let quiet = NSMenuItem(title: model.quiet ? "继续走动" : "安静一会",
                              action: #selector(toggleQuiet), keyEquivalent: "")
        quiet.target = self
        menu.addItem(quiet)
        let outfits = NSMenuItem(title: "换装",action: nil,keyEquivalent: "")
        let outfitMenu = NSMenu(title: "换装")
        for outfit in Outfit.allCases {
            let item = NSMenuItem(title: outfit.title,action: #selector(changeOutfit(_:)),keyEquivalent: "")
            item.target = self;item.representedObject = outfit.rawValue
            item.state = model.outfit == outfit ? .on : .off
            outfitMenu.addItem(item)
        }
        outfits.submenu = outfitMenu;menu.addItem(outfits)
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
        model.quota?.addMenuItems(to: menu,at: Date())
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func findFriend() { model.meeting?.findFriend(model) }
    @objc private func toggleQuiet() { model.quiet.toggle() }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }

    @objc private func changeOutfit(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,let outfit = Outfit(rawValue: raw) else { return }
        model.chooseOutfit(outfit);needsDisplay = true
    }

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

    func draw(_ dirtyRect: NSRect,now: Date) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let grid = PixelGrid(cell: model.size.uiCell,backingScale: window?.backingScaleFactor ?? 2)
        context.saveGState(); PixelDrawing.crisp(context)
        let shadowWidth = Int((28 * model.size.cell / model.size.uiCell).rounded())
        for fill in PixelDrawing.shadow(at: anchor,height: max(0,model.position.y-model.floor),grid: grid,width: shadowWidth) { fill.draw(in: context) }
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
        guard !model.inMeeting && model.state == .done else { return false }
        return PixelMotion.pose("jump",time: max(0,time-model.actSince),duration: 0.8,steps: 4).y != 0
    }

    var batteryOrigin: CGPoint { batteryOrigin(now: Date()) }
    func batteryOrigin(now: Date) -> CGPoint {
        separatedQuotaOrigin(now: now)
    }

    func bubbleLayout(above r: NSRect) -> PixelBubble.Layout? {
        let text = time < model.speechUntil ? model.speech : ""
        let thinking = !model.inMeeting && model.state == .thinking, working = !model.inMeeting && model.state == .working
        guard !text.isEmpty || thinking || working else { return nil }
        let grid = PixelGrid(cell: model.size.uiCell,backingScale: window?.backingScaleFactor ?? 2)
        return PixelBubble.layout(text: text,detail: model.inMeeting ? "" : (model.detail.isEmpty ? "努力工作中" : model.detail),
            thinking: thinking,working: working,sprite: r,anchor: anchor,bounds: bounds,
            worldY: grid.snap(model.position.y),screenTop: model.visibleFrame.maxY,
            reserveTop: 0,grid: grid,ink: "1E2A44",time: time)
    }

    private func drawBubble(above r: NSRect) {
        guard let layout = bubbleLayout(above: r), let context = NSGraphicsContext.current?.cgContext else { return }
        PixelBubble.draw(layout,text: time < model.speechUntil ? model.speech : "",
            detail: model.inMeeting ? "" : (model.detail.isEmpty ? "努力工作中" : model.detail),working: !model.inMeeting && model.state == .working,ink: "1E2A44",in: context)
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
    private let logQueue = DispatchQueue(label: "local.codexpet.log-reader",qos: .utility)
    private var polling = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let initialScreen = NSScreen.main ?? NSScreen.screens.first else {
            fputs("CodexPet: no screen available.\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }
        screen = initialScreen
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/pet")
        let lines = SpeechLines(url: directory.appendingPathComponent("codex-lines.json"))
        lines.reloadIfChanged()
        reader = StateReader(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"))
        let now = ProcessInfo.processInfo.systemUptime
        model = PetModel(frame: initialScreen.visibleFrame, lines: lines, now: now)
        model.meeting = MeetingCoordinator(directory: directory)
        petView = PetView(model: model)
        petView.time = now
        petView.controller = self
        window = PetWindow(contentRect: NSRect(origin: .zero, size: model.size.canvas),
                           styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "CodexPet"
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
        let grid = PixelGrid(cell: model.size.uiCell,backingScale: window.backingScaleFactor)
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
            if !polling {
                polling = true
                logQueue.async { [weak self] in
                    guard let self = self else { return }
                    let snapshot = self.reader.poll()
                    DispatchQueue.main.async {
                        self.polling = false
                        self.model.quota = snapshot.quota
                        self.model.receive(snapshot.signal(at: Date()),now: ProcessInfo.processInfo.systemUptime)
                    }
                }
            }
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
