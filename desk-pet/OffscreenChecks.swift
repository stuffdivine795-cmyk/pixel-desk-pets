// Appended to DeskPet.swift without its application entry point by check.sh.
// No application, window, real state/lines files, or real UserDefaults are touched.
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
}
let testRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let costumeOutput = URL(fileURLWithPath: CommandLine.arguments[3])
try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
let stateURL = testRoot.appendingPathComponent("state.json")
let linesURL = testRoot.appendingPathComponent("lines.json")
try? FileManager.default.removeItem(at: stateURL)
try? FileManager.default.removeItem(at: linesURL)
func writeState(_ text: String) throws { try Data(text.utf8).write(to: stateURL, options: .atomic) }
let reader = StateReader(url: stateURL)
check(reader.poll()?.state == .idle, "missing state falls back to idle")
check(reader.poll() == nil, "unchanged missing file is cached")
try writeState(#"{"state":"working","detail":"Bash","outfit":"party"}"#)
let signal = reader.poll()!
check(signal.state == .working && signal.detail == "Bash" && signal.outfit == "party", "state/detail/outfit decode")
check(reader.poll() == nil, "unchanged file is cached")
try writeState(#"{"state":"working","detail":"Read","outfit":"witch"}"#)
check(reader.poll()?.detail == "Read", "atomic rewrite reloads detail")
for invalid in ["not JSON", #"{"state":"sleeping"}"#, #"{"state":"unknown"}"#] {
    try writeState(invalid)
    check(reader.poll()?.state == .idle, "invalid external state falls back to idle")
}
try FileManager.default.removeItem(at: stateURL)
check(reader.poll()?.state == .idle, "deleted state falls back to idle")
let lines = SpeechLines(url: linesURL)
lines.reloadIfChanged()
for mood in PetState.allCases { check(!lines.line(for: mood).isEmpty, "fallback Chinese speech") }
try Data(#"{"idle":["测试台词"],"working":["工作台词"],"click":["摸摸"]}"#.utf8).write(to: linesURL, options: .atomic)
lines.reloadIfChanged()
check(lines.line(for: .idle) == "测试台词", "custom lines load")
check(lines.line(for: .working, clicked: true) == "摸摸 工作台词", "click includes greeting and state line")
try Data(#"{"idle":["重新加载"],"error":[]}"#.utf8).write(to: linesURL, options: .atomic)
lines.reloadIfChanged()
check(lines.line(for: .idle) == "重新加载", "lines reload")
check(!lines.line(for: .error).isEmpty, "empty group falls back")
try Data("{broken".utf8).write(to: linesURL, options: .atomic)
lines.reloadIfChanged()
check(!lines.line(for: .thinking).isEmpty, "malformed lines fall back")

// In-memory defaults keep checks from writing preferences outside the workspace.
let preferences = MemoryDefaults()
let frame = NSRect(x: 0,y: 0,width: 1440,height: 900)
func newModel(_ now: Double = 1000) -> PetModel {
    PetModel(frame: frame,lines: lines,now: now,preferences: preferences)
}
let model = newModel()
check(model.outfit == .witch, "default witch outfit")
check(model.size == .medium && model.size.cell == 8, "default cell size is eight points")
// Use an in-memory preferences subclass to test the real persistence API without disk writes.
final class MemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}
let memory = MemoryDefaults()
let dressed = PetModel(frame: frame,lines: lines,now: 1000,preferences: memory)
for outfit in Outfit.allCases {
    dressed.chooseOutfit(outfit)
    check(dressed.outfit == outfit, "menu outfit applies: \(outfit.rawValue)")
    check(PetModel(frame: frame,lines: lines,now: 1000,preferences: memory).outfit == outfit, "outfit survives model recreation")
}
dressed.chooseOutfit(.crown)
dressed.receive(PetSignal(state: .idle,detail: "",ts: nil,outfit: "santa"),now: 1001)
check(dressed.outfit == .santa, "file outfit applies without mood change")
dressed.chooseOutfit(.flower)
check(dressed.outfit == .flower, "a later menu choice wins over the file")
dressed.receive(.idle,now: 1002)
check(dressed.outfit == .flower, "a file without outfit keeps the menu choice")
dressed.receive(PetSignal(state: .idle,detail: "",ts: nil,outfit: "santa"),now: 1002)
check(dressed.outfit == .flower, "the same file outfit again does not undo the menu choice")
dressed.receive(PetSignal(state: .idle,detail: "",ts: nil,outfit: "crown"),now: 1002)
check(dressed.outfit == .crown, "a new file outfit wins over the menu choice")
dressed.receive(PetSignal(state: .working,detail: "Bash",ts: nil,outfit: "future"),now: 1003)
check(dressed.state == .working && dressed.outfit == .crown, "unknown outfit does not invalidate mood")

let sizingMemory = MemoryDefaults()
let sized = PetModel(frame: frame,lines: lines,now: 1000,preferences: sizingMemory)
for size in PetSize.allCases {
    sized.chooseSize(size)
    check(sized.size == size && sized.position.y == sized.floor, "resizing keeps feet grounded")
    let restored = PetModel(frame: frame,lines: lines,now: 1000,preferences: sizingMemory)
    check(restored.size == size, "size survives model recreation")
    let sizeView = PetView(model: restored)
    check(sizeView.bounds.size == size.canvas && sizeView.anchor == size.anchor, "canvas and anchor scale with size")
    let sizesMenu = sizeView.contextMenu().item(withTitle: "大小")!.submenu!
    check(sizesMenu.items.map(\.title) == ["小","中","大"], "size submenu lists all three sizes")
    check(sizesMenu.items.filter { $0.state == .on }.first?.representedObject as? String == size.rawValue,
          "size submenu marks current persisted size")
    restored.actIndex = 0; restored.direction = 1
    check(sizeView.containsCharacter(CGPoint(x: sizeView.anchor.x+4*size.cell,y: sizeView.anchor.y+3*size.cell)),
          "outer body hit pixels grow with size")
    check(!sizeView.containsCharacter(CGPoint(x: sizeView.anchor.x+20*size.cell,y: sizeView.anchor.y)),
          "transparent space still passes through at every size")
    restored.position.x = frame.maxX-restored.edgeInset-0.01
    restored.nextPause = 2000
    restored.step(dt: 0.25,now: 1000.25)
    check(restored.direction == -1 && restored.position.x == frame.maxX-restored.edgeInset, "scaled walking edge turns around")
    let x = restored.position.x
    restored.direction = -1
    restored.step(dt: 0.125,now: 1000.375)
    check(abs(restored.position.x-x+25*size.scale*0.125) < 0.001, "travel stride scales with size")
}
sizingMemory.set("future",forKey: "size")
check(PetModel(frame: frame,lines: lines,now: 1000,preferences: sizingMemory).size == .medium, "invalid saved size falls back to medium")

// Cross-check the name/mood contract from panel-reference-v2.tsx, including forbidden moods.
let expectedCostumes: [Outfit: [(String, [PetState])]] = [
    .witch: [("骑扫帚",[.idle,.done]),("熬魔药",[.idle,.working])],
    .party: [("吹喇叭",[.idle,.done]),("彩带舞",[.idle,.done])],
    .crown: [("坐王座",[.idle,.thinking]),("检阅",[.idle])],
    .headphones: [("摇头听歌",[.idle,.thinking,.working]),("打碟",[.idle,.done])],
    .santa: [("送礼物",[.idle,.done]),("下雪啦",[.idle,.sleeping])],
    .grad: [("抛帽子",[.idle,.done]),("念毕业词",[.idle,.thinking])],
    .flower: [("浇花",[.idle,.working]),("闻花香",[.idle,.sleeping])],
    .none: [("开合跳",[.idle,.done]),("吹泡泡",[.idle,.thinking])]
]
check(Act.costumes.values.reduce(0) { $0+$1.count } == 16, "sixteen costume acts")
for outfit in Outfit.allCases {
    check(Act.costumes[outfit]!.map { $0.act.name } == expectedCostumes[outfit]!.map { $0.0 }, "two signature acts per costume")
    for mood in PetState.allCases {
        let allowed = expectedCostumes[outfit]!.filter { $0.1.contains(mood) }.map { $0.0 }
        check(Act.costumeActs(outfit: outfit,mood: mood).map(\.name) == allowed, "exact costume mood filtering")
        let picker = newModel()
        picker.chooseOutfit(outfit); picker.state = mood
        var costumePicks = 0
        for _ in 0..<2000 {
            picker.chooseAct(now: 1001)
            let isCostume = allowed.contains(picker.act.name)
            costumePicks += isCostume ? 1 : 0
            check(isCostume || Act.all[mood]!.contains { $0.name == picker.act.name }, "picker never uses forbidden costume acts")
        }
        check(allowed.isEmpty ? costumePicks == 0 : (800...1200).contains(costumePicks), "approximately half costume picks when available")
    }
}
let switched = newModel()
switched.actIndex = Act.all[.idle]!.count // witch broom
switched.chooseOutfit(.santa)
check(switched.availableActs.contains { $0.name == switched.act.name } && switched.act.name != "骑扫帚", "menu outfit change replaces old costume act immediately")
switched.receive(PetSignal(state: .idle,detail: "",ts: nil,outfit: "grad"),now: 1002)
check(switched.actSince == 1002 && switched.outfit == .grad, "file-only outfit change resets act")

let expectedTravel = Set(["散步","踱步","搬箱子","团团转","送礼物","检阅"])
check(Act.all.values.reduce(0) { $0+$1.count } == 24, "all 24 acts present")
for mood in PetState.allCases {
    for (index,act) in Act.all[mood]!.enumerated() {
        let m = newModel()
        m.state = mood; m.stateSince = 1000; m.actIndex = index
        m.nextAct = 2000; m.nextPause = 2000; m.direction = 1
        let startX = m.position.x
        m.step(dt: 0.25,now: 1000.25)
        check((m.position.x != startX) == expectedTravel.contains(act.name), "only travel acts move: \(act.name)")
        m.quiet = true
        let stoppedX = m.position.x
        m.step(dt: 0.25,now: 1000.5)
        check(m.position.x == stoppedX, "quiet stops travel: \(act.name)")
        for _ in 0..<12 {
            m.chooseAct(now: 1001)
            check(m.nextAct == 1010 && m.actSince == 1001, "nine-second random act timing")
        }
    }
}
for outfit in Outfit.allCases {
    for costume in Act.costumes[outfit]! {
        for mood in costume.moods {
            let m = newModel()
            m.chooseOutfit(outfit); m.state = mood
            m.actIndex = Act.all[mood]!.count + Act.costumeActs(outfit: outfit,mood: mood).firstIndex { $0.name == costume.act.name }!
            m.nextAct = 2000; m.nextPause = 2000; m.direction = 1
            let x = m.position.x
            m.step(dt: 0.25,now: 1000.25)
            check((m.position.x != x) == expectedTravel.contains(costume.act.name), "costume travel/stationary contract: \(costume.act.name)")
            m.quiet = true
            let stopped = m.position.x
            m.step(dt: 0.25,now: 1000.5)
            check(m.position.x == stopped, "quiet stops costume travel")
        }
    }
}
model.actIndex = 0; model.nextPause = 10000
let startX = model.position.x
model.step(dt: 0.1,now: 1000.1)
check(model.position.x == startX, "travel holds between pixel frames")
model.step(dt: 0.025,now: 1000.125)
check(abs(model.position.x-startX+3.125*model.size.scale) < 0.001, "travel advances at 0.125-second cadence")
let priorActTime = model.actSince
model.receive(PetSignal(state: .working,detail: "Bash",ts: nil),now: 1001)
check(model.actSince == 1001 && model.actSince != priorActTime, "state change resets act")
model.receive(PetSignal(state: .working,detail: "Read",ts: nil),now: 1002)
check(model.detail == "Read" && model.actSince == 1001, "detail-only update preserves act timing")
model.step(dt: 0,now: 1010)
check(model.actSince == 1010, "automatic act rotation after nine seconds")
model.receive(PetSignal(state: .error,detail: "",ts: nil),now: 1011)
model.step(dt: 0,now: 2000)
check(model.state == .error, "error persists")
model.receive(.idle,now: 2001)
model.step(dt: 0,now: 2180.99)
check(model.state == .idle, "idle stays awake before three minutes")
model.step(dt: 0,now: 2181)
check(model.state == .sleeping, "three-minute sleep")
model.click(now: 2182)
check(model.state == .idle && model.trick != nil && model.speechUntil == 2185, "click wakes, starts trick, and speaks")
model.step(dt: 0,now: 2183)
check(model.trick == nil, "click trick finishes")
model.receive(PetSignal(state: .done,detail: "",ts: nil),now: 2184)
model.step(dt: 0,now: 2190)
check(model.state == .idle, "done returns to idle after six seconds")
model.receive(PetSignal(state: .done,detail: "",ts: 999),now: 2191)
check(model.state == .idle, "unchanged done signal does not loop")
model.actIndex = 0; model.nextPause = 9999
model.position.x = frame.maxX-model.edgeInset-0.01; model.direction = 1
model.step(dt: 0.25,now: 2192)
check(model.direction == -1 && model.position.x == frame.maxX-model.edgeInset, "screen edge turns travel around")
model.dragging = true; model.position.y = model.floor+240
model.step(dt: 0.1,now: 2192.1)
check(model.position.y == model.floor+240, "drag suspends gravity")
model.releaseDrag(now: 2193)
for i in 1...180 { model.step(dt: 1.0/60,now: 2193+Double(i)/60) }
check(model.grounded, "release falls back to floor")
model.setScreen(NSRect(x: 1440,y: 100,width: 1920,height: 1080))
check(model.position.y == 100+4.5*model.size.uiCell && model.position.x >= 1544, "screen change updates scaled floor and bounds")

check(PixelMotion.sample([(0,0),(0.5,10),(1,0)],phase: 0.24,steps: 2) == 0, "CSS steps apply per keyframe interval")
check(PixelMotion.sample([(0,0),(0.5,10),(1,0)],phase: 0.26,steps: 2) == 5, "CSS steps quantize interpolation")
check(PixelMotion.pose("flat",time: 0.99,once: true).angle == 0, "flat waits for one-second step")
check(PixelMotion.pose("flat",time: 1,once: true).angle == 90, "flat holds final frame")
check(PixelMotion.pose("blink",time: 3.6,duration: 3.7).opacity == 0, "slit eyes blink")
check(PixelMotion.pose("rise",time: 0.3,duration: 1.6,steps: 4,delay: 0.8).opacity == 0, "delayed notes start hidden")
check(PixelMotion.pose("float",time: 0,duration: 1.6,steps: 4).y == -0.5 &&
      PixelMotion.pose("float",time: 0.8,duration: 1.6,steps: 4).y == -1.5, "broom floats above the ground throughout its cycle")
check(PixelMotion.pose("snow",time: 1.2,duration: 2.4,steps: 8).y == 3.5, "snow falls through seven cells")
check(PixelMotion.pose("rise",time: 0.8,duration: 1.4,steps: 4,delay: 0.9).opacity == 0, "third potion bubble starts after its delay")
check(PixelMotion.pose("stir",time: 0.61,duration: 0.8,steps: 2).x == 1, "stir returns toward implicit identity keyframe")
check(PixelMotion.hornLength(time: 0.45) == 4, "horn remains extended in second half of cycle")

func coloredBounds(_ primitives: [PixelPrimitive], _ hex: String) -> CGRect {
    let rgb = UInt32(hex,radix: 16)!
    return primitives.filter { p in
        let c = p.color.components!
        return abs(c[0]-CGFloat((rgb>>16)&255)/255) < 0.001 &&
            abs(c[1]-CGFloat((rgb>>8)&255)/255) < 0.001 && abs(c[2]-CGFloat(rgb&255)/255) < 0.001
    }.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
}
let tossAct = Act.costumes[.grad]![0].act
let tossFrames = [0.0,0.8,1.6].map { time in
    PixelSprite.primitives(mood: .idle,act: tossAct,outfit: .grad,elapsed: time,anchor: .zero,mirrored: false,walking: false)
}
check(coloredBounds(tossFrames[1],C.hat).minY-coloredBounds(tossFrames[0],C.hat).minY == 32, "cap flies four cells up")
check(coloredBounds(tossFrames[0],C.hat) == coloredBounds(tossFrames[2],C.hat), "cap returns to head at end of toss")
check(coloredBounds(tossFrames[0],C.body) == coloredBounds(tossFrames[1],C.body), "hat toss does not throw the body")
let potion = Act.costumes[.witch]![1].act
let stirring = [0.0,0.4].map { time in
    PixelSprite.primitives(mood: .idle,act: potion,outfit: .witch,elapsed: time,anchor: .zero,mirrored: false,walking: false)
}
check(coloredBounds(stirring[1],C.wood).minX-coloredBounds(stirring[0],C.wood).minX == 8, "held spoon moves with stirring arm")
let throne = PixelSprite.primitives(mood: .idle,act: Act.costumes[.crown]![0].act,outfit: .crown,elapsed: 0,
                                    anchor: .zero,mirrored: false,walking: false)
check(throne.first!.color.components![0] == CGFloat(0xD8)/255, "throne back prop precedes body in drawing order")
let thoughtPixels = PixelSprite.primitives(mood: .thinking,act: Act.all[.thinking]![0],outfit: .none,elapsed: 1.3,
                                           anchor: .zero,mirrored: false,walking: false)
check(!coloredBounds(thoughtPixels,C.edge).isNull, "thought bubble has visible grey outline")

let viewModel = newModel()
viewModel.chooseOutfit(.none); viewModel.actIndex = 0; viewModel.direction = 1
let view = PetView(model: viewModel)
view.time = 1000.1
check(view.containsCharacter(CGPoint(x: view.anchor.x,y: view.anchor.y+20)), "body pixels accept mouse")
check(view.hitTest(CGPoint(x: 2,y: 2)) == nil, "transparent canvas passes mouse through")
let nude = PixelSprite.primitives(mood: .idle,act: Act.all[.idle]![0],outfit: .none,elapsed: 0.1,
                                 anchor: .zero,mirrored: false,walking: false)
let nudeBounds = nude.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
check(nudeBounds.width == 112, "default eight-point cells give a 112-point arm span")
for size in PetSize.allCases {
    for mood in PetState.allCases {
        for outfit in Outfit.allCases {
            for act in Act.all[mood]! + Act.costumeActs(outfit: outfit,mood: mood) {
                for time in [0.0,0.27,0.65,0.8,1.55,1.6,2.45,5.8,8.9] {
                    let a = PixelSprite.primitives(mood: mood,act: act,outfit: outfit,elapsed: time,
                                                  anchor: size.anchor,mirrored: false,walking: act.walk,cell: size.cell)
                    let b = PixelSprite.primitives(mood: mood,act: act,outfit: outfit,elapsed: time,
                                                  anchor: size.anchor,mirrored: true,walking: act.walk,cell: size.cell)
                    check(!a.isEmpty && a.count == b.count, "both facings render")
                    for primitive in a+b {
                        let box = primitive.path.boundingBoxOfPath
                        check(box.minX >= 0 && box.maxX <= size.canvas.width && box.minY >= 0 && box.maxY < size.canvas.height,
                              "sprite/hat/props fit scaled canvas: \(act.name) / \(size.title)")
                    }
                    let left = a.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
                    let right = b.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
                    check(abs(left.minX+right.maxX-size.canvas.width) < 0.51, "left-facing sprite mirrors all props")
                    if act.travel {
                        for bounds in [left,right] {
                            check(bounds.minX-size.anchor.x >= -13*size.cell && bounds.maxX-size.anchor.x <= 13*size.cell,
                                  "walking inset fits costume and both facings")
                        }
                    }
                }
            }
        }
    }
}

let width = 1500, height = 2050
let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: false)
context.setFillColor(CGColor(srgbRed: 0.94,green: 0.92,blue: 0.88,alpha: 1))
context.fill(CGRect(x: 0,y: 0,width: width,height: height))
func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 13) {
    (text as NSString).draw(at: CGPoint(x: x,y: y),withAttributes: [.font: NSFont.systemFont(ofSize: size,weight: .medium),
                                                                  .foregroundColor: NSColor(calibratedWhite: 0.18,alpha: 1)])
}
label("像素小橘 · 全部 24 个动作 / 8 套装扮 / 3 种点击特技",24,2010,22)
label("同一 Swift/Core Graphics 绘图器 · 1 cell = 6 pt · 每格四帧 t = 0.10 / 0.65 / 1.55 / 2.45 s",24,1983)
for (i,outfit) in Outfit.allCases.enumerated() {
    let x = CGFloat(i)*184+100
    PixelSprite.draw(PixelSprite.primitives(mood: .idle,act: Act.all[.idle]![1],outfit: outfit,elapsed: 0.65,
                                           anchor: CGPoint(x: x,y: 1870),mirrored: false,walking: false,pixelScale: 1,cell: 6),in: context)
    label(outfit.title,x-28,1844)
}
var actNumber = 0
for mood in PetState.allCases {
    for act in Act.all[mood]! {
        let col = actNumber%3, row = actNumber/3
        let x = CGFloat(col)*500, top = CGFloat(1810-row*190)
        let outfit = Outfit.allCases[actNumber%8]
        context.setFillColor(CGColor(gray: 1,alpha: 0.45))
        context.fill(CGRect(x: x+8,y: top-180,width: 484,height: 177))
        label("\(mood.rawValue) · \(act.name) · \(outfit.title)\(act.travel ? " · ← 行走" : "")",x+18,top-26,15)
        for (j,time) in [0.1,0.65,1.55,2.45].enumerated() {
            let center = x+65+CGFloat(j)*122
            let pixels = PixelSprite.primitives(mood: mood,act: act,outfit: outfit,elapsed: time,
                                               anchor: CGPoint(x: center,y: top-142),mirrored: act.travel,walking: act.walk,pixelScale: 1,cell: 6)
            PixelSprite.draw(pixels,in: context)
            label(String(format: "%.2fs",time),center-19,top-168,11)
        }
        actNumber += 1
    }
}
for (i,trick) in Trick.allCases.enumerated() {
    let x = CGFloat(i)*500
    label("点击特技 · \(trick.rawValue)",x+18,256,15)
    for (j,part) in [0.1,0.3,0.5,0.78].enumerated() {
        let pixels = PixelSprite.primitives(mood: .idle,act: Act.all[.idle]![1],outfit: .witch,elapsed: 0.65,
                                           anchor: CGPoint(x: x+65+CGFloat(j)*122,y: 150),mirrored: false,walking: false,
                                           trick: trick,trickTime: part*trick.duration,pixelScale: 1,cell: 6)
        PixelSprite.draw(pixels,in: context)
    }
}
label("离屏验证；未启动桌面窗口。行走在实际桌面横移，画廊只展示朝左的姿态和道具。",24,65)
let image = context.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try rep.representation(using: .png,properties: [:])!.write(to: output)
NSGraphicsContext.restoreGraphicsState()
// All sixteen signature acts at the new default, with four phases and exact allowed moods.
let costumeWidth = 1600, costumeHeight = 2550
let costumeContext = CGContext(data: nil,width: costumeWidth,height: costumeHeight,bitsPerComponent: 8,bytesPerRow: costumeWidth*4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: costumeContext,flipped: false)
costumeContext.setFillColor(CGColor(srgbRed: 0.94,green: 0.92,blue: 0.88,alpha: 1))
costumeContext.fill(CGRect(x: 0,y: 0,width: costumeWidth,height: costumeHeight))
label("像素小橘 · 全部 16 个装扮专属动作",24,2506,24)
label("应用同一绘图器 · 默认 1 cell = 8 pt · 四帧 0.00 / 0.40 / 0.80 / 1.60 s · 阴影固定在地面",24,2477,15)
var costumeNumber = 0
for outfit in Outfit.allCases {
    for costume in Act.costumes[outfit]! {
        let act = costume.act
        let x = CGFloat(costumeNumber%2)*800, top = CGFloat(2450-costumeNumber/2*250)
        costumeContext.setFillColor(CGColor(gray: 1,alpha: 0.7))
        costumeContext.fill(CGRect(x: x+8,y: top-244,width: 784,height: 238))
        label("\(outfit.title) · \(act.name)\(act.travel ? " · ← 沿桌底行走" : "")",x+20,top-30,18)
        label("适用：" + costume.moods.map(\.rawValue).joined(separator: " / "),x+20,top-53,13)
        for (j,time) in [0.0,0.4,0.8,1.6].enumerated() {
            let center = x+110+CGFloat(j)*195, ground = top-192
            for fill in PixelDrawing.shadow(at: CGPoint(x: center,y: ground),height: 0,grid: PixelGrid(cell: 8,backingScale: 1),width: 40) { fill.draw(in: costumeContext) }
            let pixels = PixelSprite.primitives(mood: .idle,act: act,outfit: outfit,elapsed: time,
                                               anchor: CGPoint(x: center,y: ground),mirrored: act.travel,walking: act.walk,pixelScale: 1)
            PixelSprite.draw(pixels,in: costumeContext)
            label(String(format: "%.2fs",time),center-20,top-224,12)
        }
        costumeNumber += 1
    }
}
check(costumeNumber == 16, "costume gallery includes all sixteen acts")
label("大小 · 菜单选择保存到 UserDefaults",24,413,18)
for (i,size) in PetSize.allCases.enumerated() {
    let center = CGFloat(145+i*270)
    let pixels = PixelSprite.primitives(mood: .idle,act: Act.all[.idle]![1],outfit: .witch,elapsed: 0.65,
                                       anchor: CGPoint(x: center,y: 230),mirrored: false,walking: false,pixelScale: 1,cell: size.cell)
    PixelSprite.draw(pixels,in: costumeContext)
    label("\(size.title) · \(Int(size.cell)) pt\(size == .medium ? "（默认）" : "")",center-55,195,15)
}
costumeContext.setFillColor(CGColor(gray: 1,alpha: 1))
costumeContext.fill(CGRect(x: 860,y: 155,width: 710,height: 235))
label("思考泡泡 · 白底上的灰色轮廓",885,358,17)
PixelSprite.draw(PixelSprite.primitives(mood: .thinking,act: Act.all[.thinking]![0],outfit: .witch,elapsed: 1.3,
                                       anchor: CGPoint(x: 1120,y: 215),mirrored: false,walking: false,pixelScale: 1),in: costumeContext)
label("离屏静态帧已生成；桌面窗口、拖拽、菜单交互与实际动画播放需由用户启动后确认。",24,76,15)
let costumeImage = NSBitmapImageRep(cgImage: costumeContext.makeImage()!)
try costumeImage.representation(using: .png,properties: [:])!.write(to: costumeOutput)
NSGraphicsContext.restoreGraphicsState()
// Also exercise the actual NSView speech/detail layout, rather than only the sprite renderer.
let bubbleContext = CGContext(data: nil,width: 1440,height: 960,bitsPerComponent: 8,bytesPerRow: 1440*4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: bubbleContext,flipped: false)
for (i,mood) in PetState.allCases.enumerated() {
    let origin = CGPoint(x: (i%3)*480,y: (1-i/3)*480)
    bubbleContext.saveGState()
    bubbleContext.translateBy(x: origin.x,y: origin.y)
    bubbleContext.clip(to: view.bounds)
    viewModel.chooseOutfit(Outfit.allCases[i+1])
    viewModel.state = mood; viewModel.actIndex = 0; viewModel.actSince = 1000
    viewModel.speech = "认真做好每一小步，马上就好！"
    viewModel.speechUntil = 1004
    viewModel.detail = "Bash · 终端命令"
    view.time = 1001.55
    view.draw(view.bounds)
    label(mood.rawValue,140,8)
    bubbleContext.restoreGState()
}
let bubbleImage = NSBitmapImageRep(cgImage: bubbleContext.makeImage()!)
try bubbleImage.representation(using: .png,properties: [:])!.write(to: testRoot.appendingPathComponent("bubbles.png"))
NSGraphicsContext.restoreGraphicsState()
// Speech at the bottom left and near the top right, through the real view at every size.
let layoutContext = CGContext(data: nil,width: 1800,height: 1200,bitsPerComponent: 8,bytesPerRow: 1800*4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: layoutContext,flipped: false)
layoutContext.setFillColor(CGColor(gray: 0.95,alpha: 1))
layoutContext.fill(CGRect(x: 0,y: 0,width: 1800,height: 1200))
for (column,size) in PetSize.allCases.enumerated() {
    for row in 0..<2 {
        let m = newModel()
        m.chooseSize(size); m.chooseOutfit(.grad)
        m.actIndex = Act.all[.idle]!.count; m.actSince = 1000
        m.position.x = row == 0 ? m.edgeInset : frame.maxX-m.edgeInset
        m.position.y = row == 0 ? m.floor : frame.maxY-112*size.scale
        m.speech = String(repeating: "认真做好每一小步，马上就好！",count: 6)
        m.speechUntil = 1004
        let v = PetView(model: m)
        let windowOrigin = size.windowOrigin(position: m.position,in: frame)
        v.anchor = CGPoint(x: m.position.x-windowOrigin.x,y: m.position.y-windowOrigin.y)
        v.time = 1000.8
        // PetView clears with .copy; composite a transparent layer onto the gallery.
        let layer = CGContext(data: nil,width: Int(size.canvas.width),height: Int(size.canvas.height),bitsPerComponent: 8,
            bytesPerRow: Int(size.canvas.width)*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: layer,flipped: false)
        v.draw(v.bounds);NSGraphicsContext.restoreGraphicsState()
        layoutContext.interpolationQuality = .none
        layoutContext.draw(layer.makeImage()!,in: CGRect(x: CGFloat(column*600)+(600-size.canvas.width)/2,
            y: CGFloat((1-row)*600),width: size.canvas.width,height: size.canvas.height))
        label("\(size.title) / \(Int(size.cell)) pt · \(row == 0 ? "左下 / 上方气泡" : "右上 / 下方气泡")",CGFloat(column*600+15),CGFloat((1-row)*600+570),15)
    }
}
let layoutImage = NSBitmapImageRep(cgImage: layoutContext.makeImage()!)
try layoutImage.representation(using: .png,properties: [:])!.write(to: testRoot.appendingPathComponent("size-layouts.png"))
NSGraphicsContext.restoreGraphicsState()
print("PASS: \(checks) assertions; 24 general acts, 16 costume acts, 8 outfits, 3 sizes, 3 tricks")
print("Rendered: \(output.path)\nRendered: \(costumeOutput.path)")
