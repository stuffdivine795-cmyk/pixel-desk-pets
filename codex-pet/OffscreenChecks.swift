// Compiled with the application's exact implementation, without its GUI entry point.
var checks = 0
func check(_ condition: @autoclosure () -> Bool,_ text: String) {
    guard condition() else { fputs("FAIL: \(text)\n",stderr);exit(1) };checks += 1
}
final class MemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?,forKey key: String) { values[key] = value }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1],isDirectory: true)
try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
let now = LogDate.parse("2026-11-02T12:00:00Z")!
func record(_ type: String,_ payload: [String: Any],at date: Date = now) -> Data {
    let formatter = ISO8601DateFormatter();formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
    return try! JSONSerialization.data(withJSONObject: ["timestamp":formatter.string(from: date),"type":type,"payload":payload],options: [.sortedKeys])
}
func event(_ kind: String,_ extra: [String: Any] = [:],type: String = "response_item") -> LogMoodEvent? {
    CodexLogParser.parse(record(type,extra.merging(["type":kind],uniquingKeysWith: { _,b in b }))).0
}
check(event("task_started",type: "event_msg")?.state == .thinking,"task started")
check(event("task_complete",type: "event_msg")?.state == .done,"task complete")
for kind in ["reasoning","message"] { check(event(kind)?.state == .thinking,"thinking mapping: \(kind)") }
for kind in ["custom_tool_call","function_call"] {
    check(event(kind,["name":"read_file"])?.state == .working,"working mapping: \(kind)")
    check(event(kind,["name":"exec","arguments":#"{"cmd":"swiftc -O main.swift"}"#])?.detail == "swiftc","command detail")
}
check(event("custom_tool_call",["name":"exec","input":"not JSON"])?.detail == "exec","custom raw input uses tool name")
for field: [String: Any] in [["exit_code":1],["exitCode":2],["returncode":-1],["is_error":true],["isError":true],
                            ["status":"failed"],["status":"error"]] {
    check(event("function_call_output",field)?.state == .error,"explicit failure directly in payload")
}
for output: Any in [["exit_code":7],["isError":true],["is_error":true],["status":"failed"],["status":"ERROR"],
                    ["exitCode":-2],["returncode":3],["exit_code":0,"isError":true],["exit_code":0,"status":"failed"],
                    "Process exited with code 1", "Exit code: -1", "{\"exit_code\": 2, \"output\":\"bad\"}",
                    [["type":"input_text","text":"Script completed\nOutput:\n{\"exit_code\":1}"]]] {
    check(event("function_call_output",["output":output])?.state == .error,"explicit failed output")
}
let grepOutput = "error: printed source line\nFAIL: a test fixture\nTraceback (most recent call last):\nfatal error: example"
for kind in ["custom_tool_call_output","function_call_output"] {
    for key in ["exit_code","exitCode","returncode"] {
        check(event(kind,["output":[key:0,"output":grepOutput]])?.state == .working,"grep-like output with zero exit stays working")
        check(event(kind,["output":[key:1,"output":grepOutput]])?.state == .error,"grep-like output with exit one is error")
    }
}
for output: Any in [["exit_code":0], ["error":NSNull()], ["error":"permission denied"],grepOutput,
                    ["content":[["type":"text","text":"Error: unavailable"]]],
                    ["exit_code":false],["exit_code":true],["exit_code":"1"],["isError":1],["is_error":"true"],
                    ["isError":false],["status":"working"],"all 0 errors", "Process exited with code 0", "Exit code: 0",["output":"no error"],
                    ["exit_code":0,"output":"source example: {\"exit_code\":7}\nError: literal from a test"],
                    #"{"exit_code":0,"output":"example: {\"exit_code\":1}"}"#] {
    check(event("custom_tool_call_output",["output":output])?.state == .working,"successful output clears error")
}
check(event("function_call_output",["error":"only diagnostic text"])?.state == .working,"error field alone is not an explicit failure")
check(event("function_call_output",["output":"Process exited with code 0\nOutput:\n"+grepOutput])?.state == .working,"text-wrapped grep result stays working")
check(event("function_call_output",["output":"Exit code: 1\nOutput:\n"+grepOutput])?.state == .error,"text-wrapped failure still reports error")
check(event("future_event") == nil,"unknown payload ignored")
check(event("reasoning",type: "unknown") == nil,"unknown outer type ignored")
check(CodexLogParser.parse(Data("{bad".utf8)).0 == nil,"malformed JSON ignored")
check(CodexLogParser.parse(Data(#"{"type":"event_msg","payload":{"type":"task_started"}}"#.utf8)).0 == nil,"missing timestamp ignored")

let rate: [String: Any] = ["primary":["used_percent":57,"resets_at":now.addingTimeInterval(3600).timeIntervalSince1970],
                          "secondary":["used_percent":70,"resets_at":now.addingTimeInterval(7*86400).timeIntervalSince1970]]
for payload: [String: Any] in [["type":"token_count","rate_limits":rate],["type":"token_count","info":["rate_limits":rate]]] {
    let parsed = CodexLogParser.parse(record("event_msg",payload))
    check(parsed.0 == nil && parsed.1?.quota.fiveHour?.remaining(at: now) == 43,"quota independent of mood, both nesting forms")
    check(parsed.1?.quota.sevenDay?.remaining(at: now) == 30,"weekly quota")
}
let quota = QuotaSnapshot.codex(rate)
check(quota.summary(at: now) == "5h 43% · 周 30%","both windows in label")
check(quota.fiveHour?.remaining(at: now.addingTimeInterval(3601)) == 100,"reset expires to 100 percent left")
for (left,color) in [(100,"5BD38A"),(41,"5BD38A"),(40,"F2C14E"),(16,"F2C14E"),(15,"D8453B"),(0,"D8453B")] {
    check(QuotaBattery.fillHex(left) == color,"battery threshold \(left)")
}
check(QuotaWindow(used: -4,resetsAt: nil)?.remaining(at: now) == 100,"negative usage clamped")
check(QuotaWindow(used: 140,resetsAt: nil)?.remaining(at: now) == 0,"excess usage clamped")
check(QuotaWindow(used: .nan,resetsAt: nil) == nil,"invalid numeric quota hidden")
check(QuotaSnapshot.codex([:]).fiveHour == nil,"missing quota hidden")
check(QuotaSnapshot.codex(["secondary":["used_percent":5]]).sevenDay?.remaining(at: now) == 95,"weekly-only record")
let infoMenu = NSMenu();quota.addMenuItems(to: infoMenu,at: now)
check(infoMenu.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled && $0.action == nil },"quota menu items disabled")
check(quota.menuTitles(at: now).count == 2,"two quota menu lines")

for (state,age,expected) in [(PetState.working,59.9,PetState.working),(.thinking,60,.idle),(.error,59,.error),(.error,60,.idle),
                            (.working,239,.idle),(.working,240,.sleeping),(.done,5.99,.done),(.done,6,.idle),(.done,186,.sleeping)] {
    let snapshot = LogSnapshot(event: LogMoodEvent(timestamp: now.addingTimeInterval(-age),state: state,detail: "exec"))
    check(snapshot.signal(at: now).state == expected,"timestamp-based timeout \(state) / \(age)")
}

// A touched old file must lose to a newer event, and quota selection is independent.
let logs = root.appendingPathComponent("logs-\(UUID().uuidString)")
let folder = logs.appendingPathComponent("2026/11/02")
try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
let old = folder.appendingPathComponent("rollout-2026-11-02T09-00-00-old.jsonl")
let new = folder.appendingPathComponent("rollout-2026-11-02T11-00-00-new.jsonl")
func writeLines(_ lines: [Data],to url: URL) throws {
    var bytes = Data();for line in lines { bytes.append(line);bytes.append(10) };try bytes.write(to: url,options: .atomic)
}
try writeLines([record("event_msg",["type":"task_complete"],at: now.addingTimeInterval(-30)),record("event_msg",["rate_limits":rate],at: now.addingTimeInterval(-10))],to: old)
try writeLines([record("response_item",["type":"function_call","name":"inspect"],at: now)],to: new)
try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(10000)],ofItemAtPath: old.path)
let reader = StateReader(root: logs)
var snap = reader.poll(at: now)
check(snap.event?.state == .working && snap.event?.detail == "inspect","newest event wins over touched old mtime")
check(snap.quota?.fiveHour?.remaining(at: now) == 43,"quota may come from a different file")
let handle = try FileHandle(forWritingTo: new);try handle.seekToEnd()
let complete = record("event_msg",["type":"task_complete"],at: now.addingTimeInterval(1))
try handle.write(contentsOf: complete.prefix(20));try handle.close()
check(reader.poll(at: now.addingTimeInterval(1)).event?.state == .working,"partial append is buffered")
let append = try FileHandle(forWritingTo: new);try append.seekToEnd();try append.write(contentsOf: complete.dropFirst(20)+Data([10]));try append.close()
check(reader.poll(at: now.addingTimeInterval(2)).event?.state == .done,"completed appended line consumed once")
try writeLines([record("event_msg",["type":"task_started"],at: now.addingTimeInterval(3))],to: new)
check(reader.poll(at: now.addingTimeInterval(3)).event?.state == .thinking,"atomic file replacement resets incremental reader")
try writeLines([record("response_item",["type":"function_call","name":"new_file"],at: now.addingTimeInterval(4))],to: folder.appendingPathComponent("rollout-2026-11-02T12-00-00-latest.jsonl"))
check(reader.poll(at: now.addingTimeInterval(6)).event?.detail == "new_file","new session discovered")

// Check unmodified real local JSONL schemas without copying prompts or output into fixtures.
let realRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
let realFiles = FileManager.default.enumerator(at: realRoot,includingPropertiesForKeys: nil)?
    .compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
    .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(8) ?? []
var realKinds = Set<String>(),realQuotas = 0,realFailures = 0
for url in realFiles {
    guard let bytes = try? Data(contentsOf: url) else { continue }
    for line in bytes.split(separator: 10) {
        let data = Data(line)
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],let p = raw["payload"] as? [String: Any],
              let kind = p["type"] as? String else { continue }
        let parsed = CodexLogParser.parse(data)
        let outer = raw["type"] as? String
        if outer == "event_msg" && ["task_started","task_complete"].contains(kind) {
            check(parsed.0?.state == (kind == "task_started" ? .thinking : .done),"real event mood \(kind)");realKinds.insert(kind)
        } else if outer == "response_item" && ["reasoning","message","custom_tool_call","function_call"].contains(kind) {
            let expected: PetState = ["reasoning","message"].contains(kind) ? .thinking : .working
            check(parsed.0?.state == expected,"real response mood \(kind)");realKinds.insert(kind)
        }
        if parsed.0?.state == .error { realFailures += 1 }
        if parsed.1?.quota.fiveHour != nil { realQuotas += 1 }
    }
}
check(realKinds.isSuperset(of: ["task_started","task_complete","reasoning","message","custom_tool_call"]),"real log coverage")
check(realQuotas > 0,"real quota records read")
print("Real logs: \(realKinds.sorted().joined(separator: ", ")); \(realQuotas) quotas; \(realFailures) explicit failures")

let linesURL = root.appendingPathComponent("test-lines-\(UUID().uuidString).json")
let lines = SpeechLines(url: linesURL);lines.reloadIfChanged()
for mood in PetState.allCases { check(!lines.line(for: mood).isEmpty,"missing lines have fallback") }
try Data(#"{"idle":["小雨"],"click":["扑通"],"error":[]}"#.utf8).write(to: linesURL,options: .atomic)
lines.reloadIfChanged();check(lines.line(for: .idle,clicked: true) == "扑通 小雨","custom click and state lines")
try Data(#"{"idle":["重载"]}"#.utf8).write(to: linesURL,options: .atomic)
lines.reloadIfChanged();check(lines.line(for: .idle) == "重载","lines reload after change")
try FileManager.default.removeItem(at: linesURL);lines.reloadIfChanged()
check(!lines.line(for: .idle).isEmpty,"deleted lines restore fallbacks")
let frame = CGRect(x: 0,y: 0,width: 1440,height: 900)
func model(_ time: Double = 1000) -> PetModel { PetModel(frame: frame,lines: lines,now: time,preferences: MemoryDefaults()) }
let m = model()
check(m.size == .medium && m.size.cell == 6 && m.size.uiCell == 8,"smaller drop and unchanged default UI scale")
check(m.position.x < frame.midX,"launch on left")
for mood in PetState.allCases {
    m.state = mood;var signatures = 0
    for _ in 0..<1500 { m.chooseAct(now: 1000);if !m.act.signature.isEmpty { signatures += 1 } }
    check(Act.signatures[mood] == nil ? signatures == 0 : (600...900).contains(signatures),"signature selection near half for \(mood)")
}
let walking = model();walking.actIndex = 0;walking.nextPause = 9999
let beforeX = walking.position.x;walking.step(dt: 0.25,now: 1000.25)
check(walking.position.x > beforeX,"idle walks along floor")
walking.quiet = true;let quietX = walking.position.x;walking.step(dt: 1,now: 1001)
check(walking.position.x == quietX,"quiet stops movement")
let sleepy = model();sleepy.step(dt: 0,now: 1180)
check(sleepy.state == .sleeping,"three minutes idle sleeps")
sleepy.click(now: 1181);check(sleepy.state == .idle && sleepy.trick != nil && !sleepy.speech.isEmpty,"click wakes, tricks, speaks")
let wake = model();wake.receive(PetSignal(state: .working,detail: "a",ts: 1),now: 1000)
wake.receive(PetSignal(state: .idle,detail: "",ts: 1),now: 1060);wake.step(dt: 0,now: 1240)
wake.receive(PetSignal(state: .working,detail: "b",ts: 2),now: 1241)
check(wake.state == .working && wake.detail == "b","new event wakes idle/sleeping despite same prior mood")
let repeatedDone = model()
repeatedDone.receive(PetSignal(state: .done,detail: "",ts: 1),now: 1000)
repeatedDone.receive(PetSignal(state: .done,detail: "",ts: 2),now: 1004)
repeatedDone.step(dt: 0,now: 1006)
check(repeatedDone.state == .done,"a second completion gets its own six seconds")
let falling = model();falling.position.y = 500;falling.dragging = true;falling.releaseDrag(now: 1000)
for i in 1...300 { falling.step(dt: 1.0/60,now: 1000+Double(i)/60) }
check(falling.grounded && falling.position.y == falling.floor,"drag release settles under gravity")
for size in PetSize.allCases {
    let sized = model();sized.chooseSize(size);let view = PetView(model: sized)
    check(size.cell == [CGFloat(4.5),6,7.5][PetSize.allCases.firstIndex(of: size)!],"requested drop cells for each size")
    check(size.uiCell == [CGFloat(6),8,10][PetSize.allCases.firstIndex(of: size)!],"DeskPet UI cells for each size")
    check(sized.position.y == sized.floor && sized.floor == frame.minY+4.5*size.uiCell,"resizing keeps the shared ground height")
    check(PixelGrid(cell: size.cell).rect(CGRect(x: 0,y: 0,width: size.cell,height: size.cell)).width*2 == size.cell*2,
          "drop cells are exactly 8/11/14 device pixels at 2x")
    check(view.contextMenu().item(withTitle: "换装")?.submenu?.items.count == 8,"eight water outfits")
    let sizes = view.contextMenu().item(withTitle: "大小")!.submenu!
    check(sizes.items.map(\.title) == ["小","中","大"],"size menu")
    view.time = 1000;sized.actIndex = 0
    check(view.containsCharacter(CGPoint(x: view.anchor.x,y: view.anchor.y+7*size.cell)),"body receives clicks")
    check(!view.containsCharacter(CGPoint(x: 5,y: 5)),"transparent pixels pass through")
    let pixels = view.sprite
    let bounds = pixels.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
    check(view.bounds.contains(bounds),"sprite fits canvas at \(size)")
}
check(PixelMotion.sample([(0,0),(0.5,-2),(1,0)],phase: 0.24,steps: 4) == -0.5,"CSS steps per keyframe interval")
private let arm = PixelMotion.pose("wave",time: 2.0,duration: 3)
check(arm.y == -2,"approved wave keyframe")
check(PixelMotion.pose("jump",time: 0.4,duration: 0.8,steps: 4).y == -2,"approved jump height")
check(PixelMotion.pose("drip",time: 0.3,duration: 0.6,steps: 3).y == 0.5,"rain step snaps to one pixel unit")
check(PixelMotion.progressWidth(16.4,time: 1.5) == 8.5,"progress width uses discrete half-cell columns")

func makeContext(_ width: Int,_ height: Int) -> CGContext {
    CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func label(_ text: String,_ x: CGFloat,_ y: CGFloat,_ font: CGFloat = 14) {
    (text as NSString).draw(at: CGPoint(x: x,y: y),withAttributes: [.font:NSFont.systemFont(ofSize: font),.foregroundColor:NSColor.darkGray])
}
// Exercise the actual view's speech, details and battery at both screen edges.
let layouts = makeContext(1800,1260)
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: layouts,flipped: false)
layouts.setFillColor(CGColor(gray: 0.95,alpha: 1));layouts.fill(CGRect(x: 0,y: 0,width: 1800,height: 1260))
for (column,size) in PetSize.allCases.enumerated() {
    for row in 0..<2 {
        let m = model();m.chooseSize(size);m.state = row == 0 ? .working : .idle
        m.actIndex = Act.all[m.state]!.count;m.actSince = 1000;m.quota = quota
        m.position.x = row == 0 ? m.edgeInset : frame.maxX-m.edgeInset
        m.position.y = row == 0 ? m.floor : frame.maxY-134*size.scale
        m.speech = String(repeating: "认真做好每一小步，马上就好！",count: 5)
        m.speechUntil = 1004;m.detail = "swiftc · 检查长工具信息是否仍然可读"
        let v = PetView(model: m),origin = size.windowOrigin(position: m.position,in: frame)
        v.anchor = CGPoint(x: m.position.x-origin.x,y: m.position.y-origin.y);v.time = 1000.4
        let box = v.sprite.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
        check(v.bounds.contains(box),"cloud/progress props fit view at screen edge and size \(size)")
        let width = Int(size.canvas.width.rounded()),height = Int(size.canvas.height.rounded())
        let layer = makeContext(width,height)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: layer,flipped: false)
        v.draw(v.bounds);NSGraphicsContext.restoreGraphicsState()
        let x = CGFloat(column*600)+(600-size.canvas.width)/2,y = CGFloat((1-row)*600)
        layouts.draw(layer.makeImage()!,in: CGRect(x: x,y: y,width: size.canvas.width,height: size.canvas.height))
        label("\(size.title) / \(size.cell) pt · \(row == 0 ? "左下，工作气泡" : "右上，下方气泡")",CGFloat(column*600+15),CGFloat((1-row)*600+580),15)
    }
}
label("实际 PetView · 三种大小 / 角落定位 / 长台词与工具信息 / 电池",20,1224,21)
let layoutImage = NSBitmapImageRep(cgImage: layouts.makeImage()!)
try layoutImage.representation(using: .png,properties: [:])!.write(to: root.appendingPathComponent("layouts.png"))
NSGraphicsContext.restoreGraphicsState()
let context = makeContext(1500,1620)
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: false)
context.setFillColor(CGColor(srgbRed: 0.93,green: 0.96,blue: 0.98,alpha: 1));context.fill(CGRect(x: 0,y: 0,width: 1500,height: 1620))
label("小水滴 · 六种心情 / 全部动作 / 额度电池",24,1572,25)
label("原生绘图器 · 水滴 6 pt / UI 8 pt · 每个动作三帧 · 电池演示值 5h 43%",24,1544,15)
let cards = PetState.allCases.flatMap { mood in (Act.all[mood]!+(Act.signatures[mood] ?? [])).map { (mood,$0) } }
check(cards.count == 10,"all ten mood/act combinations in gallery")
for (i,pair) in cards.enumerated() {
    let x = CGFloat(i%2)*750,top = CGFloat(1515-(i/2)*280)
    context.setFillColor(CGColor(gray: 1,alpha: 0.86));context.fill(CGRect(x: x+8,y: top-270,width: 734,height: 262))
    label("\(pair.0.rawValue) · \(pair.1.name)",x+20,top-34,18)
    for (j,time) in [0.0,0.4,0.8].enumerated() {
        let anchor = CGPoint(x: x+85+CGFloat(j)*245,y: top-208)
        for fill in PixelDrawing.shadow(at: anchor,height: 0,grid: PixelGrid(cell: 8,backingScale: 1),width: 20) { fill.draw(in: context) }
        let pixels = PixelSprite.primitives(mood: pair.0,act: pair.1,elapsed: time,anchor: anchor,mirrored: false,walking: pair.1.walk,pixelScale: 1)
        PixelSprite.draw(pixels,in: context)
        QuotaBattery.draw(quota,at: QuotaBattery.origin(under: anchor,left: 43,grid: PixelGrid(cell: 8,backingScale: 1)),cell: 8,now: now,in: context,pixelScale: 1,ink: "1E2A44")
        label(String(format:"%.2f s",time),anchor.x-15,top-246,12)
    }
}
label("绿色 > 40% · 黄色 > 15% · 红色 ≤ 15% · 重置后按剩余 100% 显示 · 无 5h 数据隐藏电池",24,74,15)
label("离屏检查；桌面动画播放、拖拽、跨屏与菜单实际点击留待用户启动确认。",24,45,15)
let image = NSBitmapImageRep(cgImage: context.makeImage()!)
try image.representation(using: .png,properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
NSGraphicsContext.restoreGraphicsState()
print("PASS: \(checks) CodexPet assertions; generated gallery.png with all moods/acts and quota battery")
