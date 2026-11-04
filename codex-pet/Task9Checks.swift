// Task 9: compiled with each real model/view, no application entry point or window.
let task9Start = checks
let task9Root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,isDirectory: true)
let task9Now = LogDate.parse("2026-11-02T12:00:00Z")!
let task9Frame = CGRect(x: 0,y: 100,width: 1440,height: 900)
let task9Lines = SpeechLines(url: task9Root.appendingPathComponent(".build/checks/task9-no-lines.json"))
func task9Model(_ size: PetSize = .medium) -> PetModel {
    let m = PetModel(frame: task9Frame,lines: task9Lines,now: 1000,preferences: MemoryDefaults())
    m.chooseSize(size);m.quiet = true;m.actSince = 1000
    m.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: 98,resetsAt: task9Now.addingTimeInterval(12600)))
    return m
}
func task9Bitmap(_ width: Int,_ height: Int) -> CGContext {
    CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func task9Label(_ text: String,_ x: CGFloat,_ y: CGFloat,_ context: CGContext) {
    PixelDrawing.crisp(context)
    (text as NSString).draw(at: CGPoint(x: x,y: y),withAttributes: [
        .font:NSFont.systemFont(ofSize: 15),.foregroundColor:NSColor.darkGray])
}
#if !DESK_PET
let task9Prefs = MemoryDefaults()
let task9New = PetModel(frame: task9Frame,lines: task9Lines,now: 1000,preferences: task9Prefs)
check(task9New.outfit == .none,"fresh water drop defaults to 素颜")
for outfit in Outfit.allCases {
    let v = PetView(model: task9New)
    let items = v.contextMenu().item(withTitle: "换装")!.submenu!.items
    check(items.map(\.title) == ["素颜","小黄鸭","小雨伞","潜水镜","渔夫帽","冰晶冠","荷叶帽","游泳圈"],"approved Chinese outfit menu")
    let item = items.first { $0.representedObject as? String == outfit.rawValue }!
    _ = v.perform(item.action!,with: item)
    check(task9New.outfit == outfit && task9Prefs.string(forKey: "outfit") == outfit.rawValue,"menu action writes outfit preference")
    let restored = PetModel(frame: task9Frame,lines: task9Lines,now: 1000,preferences: task9Prefs)
    check(restored.outfit == outfit,"new model restores each saved outfit")
    let updated = v.contextMenu().item(withTitle: "换装")!.submenu!.items
    check(updated.filter { $0.state == .on }.count == 1 && updated.first { $0.state == .on }?.title == outfit.title,"only current outfit is ticked")
}
task9Prefs.set("unknown",forKey: "outfit")
check(PetModel(frame: task9Frame,lines: task9Lines,now: 1000,preferences: task9Prefs).outfit == .none,"invalid outfit restores safe default")
// Verify the layering and sleeping offset against the generated approved rectangles.
for outfit in Outfit.allCases where outfit != .none {
    for mood in PetState.allCases {
        let nodes = DropOutfitGeometry.nodes(outfit)
        let pixels = PixelSprite.primitives(mood: mood,act: Act(name: "静止"),elapsed: 0,
            anchor: CGPoint(x: 240,y: 80),mirrored: false,walking: false,cell: 6,meeting: true,outfit: outfit)
        let expected = nodes.compactMap { node -> PixelPrimitive? in
            guard case .rect(let rect,let hex,_) = node else { return nil }
            return PixelPrimitive.transformed(rect,by: PixelTransform(a: 6,d: -6,tx: 168,ty: 169)
                .times(.translate(0,mood == .sleeping ? 1 : 0)),grid: PixelGrid(cell: 6),hex: hex,interactive: true)
        }
        let last = Array(pixels.suffix(expected.count))
        check(zip(last,expected).allSatisfy { $0.rect == $1.rect && $0.color == $1.color },"outfit is last body layer and follows melted tip in \(mood)")
    }
}
#endif
for (left,digits,time) in [(95,"2E9E5B","6FB98F"),(41,"2E9E5B","6FB98F"),(40,"C9971C","D9B35A"),
                          (16,"C9971C","D9B35A"),(15,"D8453B","E58A84"),(2,"D8453B","E58A84"),(0,"D8453B","E58A84")] {
    check(QuotaBattery.digitHex(left) == digits && QuotaBattery.timeHex(left) == time,"quota colour boundary \(left)")
    for second in 0...3 {
        let date = task9Now.addingTimeInterval(Double(second))
        check(QuotaBattery.outlineVisible(left,at: date) == (left >= 15 || second%2 == 0),"strictly below 15 blinks once per second")
    }
}
var task9Scenes = 0
let task9Times = Array(Set((0...72).map { Double($0)/8 } + [0.031,0.249,0.251,0.499,0.501,0.749,0.917,1.337,2.567,3.219,5.8,8.9])).sorted()
for size in PetSize.allCases { for scale: CGFloat in [1,2] {
    let m = task9Model(size),v = PetView(model: task9Model(size))
    let grid = PixelGrid(cell: size.uiCell,backingScale: scale)
    check(m.floor == task9Frame.minY+4.5*size.uiCell,"both ground lines raised by row height plus one unit")
    for outfit in Outfit.allCases { for mood in PetState.allCases {
        v.model.chooseOutfit(outfit);v.model.state = mood
        for actIndex in v.model.availableActs.indices {
            v.model.actIndex = actIndex
            for t in task9Times { for direction: CGFloat in [-1,1] {
                v.model.direction = direction;v.time = 1000+t
                #if DESK_PET
                let pixels = PixelSprite.primitives(mood: mood,act: v.model.act,outfit: outfit,elapsed: t,
                    anchor: v.anchor,mirrored: direction < 0,walking: true,pixelScale: scale,cell: size.cell)
                #else
                let pixels = PixelSprite.primitives(mood: mood,act: v.model.act,elapsed: t,
                    anchor: v.anchor,mirrored: direction < 0,walking: true,pixelScale: scale,cell: size.cell,outfit: outfit)
                #endif
                check(pixels.allSatisfy { v.bounds.contains($0.rect) },"every outfit/mood/act fits at \(size) / \(scale)x / \(mood) / \(v.model.act.name) / \(outfit) / \(t)")
                check(pixels.allSatisfy { p in [p.rect.minX,p.rect.minY,p.rect.maxX,p.rect.maxY].allSatisfy { abs($0*scale-($0*scale).rounded()) < 0.00001 } },"all outfit pixels are whole device pixels")
                if v.quotaPlateVisible {
                    let origin = QuotaBattery.origin(under: v.anchor,left: 2,grid: grid)
                    let fills = QuotaBattery.geometry(2,at: origin,grid: grid,ink: QuotaBattery.ink,resets: "03:30")
                    let row = fills.reduce(CGRect.null) { $0.union($1.rect) }
                    check(pixels.allSatisfy { !$0.rect.intersects(row) },"plate clears all sprite/prop pixels: \(mood) / \(v.model.act.name) / \(outfit) / \(t)")
                    let landedPixels = v.sprite
                    v.model.landingSquash = 1
                    check(v.sprite.allSatisfy { !$0.rect.intersects(row) },"landing bob clears plate in every outfit/mood/act")
                    v.model.landingSquash = 0
                    check(landedPixels.allSatisfy { !$0.rect.intersects(row) },"actual view clears plate")
                    check(PixelDrawing.shadow(at: v.anchor,height: 0,grid: grid,width: 40).allSatisfy { !$0.rect.intersects(row) },"shadow stays above plate")
                    if let bubble = v.bubbleLayout(above: pixels.reduce(CGRect.null) { $0.union($1.rect) }) {
                        check(bubble.fills.allSatisfy { !$0.rect.intersects(row) } && !bubble.textRect.intersects(row) && !bubble.detailRect.intersects(row),"plate clears bubbles and text")
                    }
                }
                task9Scenes += 1
            } }
        }
    } }
    let hide = task9Model(size),hideView = PetView(model: task9Model(size))
    hideView.time = 1000;hideView.model.state = .idle;hideView.model.actIndex = 0
    check(hideView.quotaPlateVisible,"plate visible on ground")
    hideView.model.dragging = true;check(!hideView.quotaPlateVisible,"plate hidden while dragging")
    hideView.model.dragging = false;hideView.model.position.y += 50;check(!hideView.quotaPlateVisible,"plate hidden in air")
    hideView.model.position.y = hideView.model.floor;hideView.model.velocityY = -1;check(!hideView.quotaPlateVisible,"plate hidden while falling")
    hideView.model.velocityY = 0
    for trick in Trick.allCases { hideView.model.trick = trick;check(!hideView.quotaPlateVisible,"plate hidden during click trick") }
    hideView.model.trick = nil;check(hideView.quotaPlateVisible,"plate returns on landing")
    hide.position.y += 100;hide.releaseDrag(now: 1000)
    for i in 1...180 { hide.step(dt: 1.0/60,now: 1000+Double(i)/60) }
    check(hide.grounded,"raised ground still accepts falling pets")
    // Compare every painted battery/digit/time pixel with the actual PetView raster, at screen edges.
    for left in [0,2,15,16,40,41,95,100] { for side: CGFloat in [-1,1] { for second in [0,1] {
        let date = task9Now.addingTimeInterval(Double(second)),m = task9Model(size)
        m.state = .working;m.actIndex = 0;m.speech = "认真检查，每一步都算数。";m.speechUntil = 1005
        m.position.x = side < 0 ? task9Frame.minX+m.edgeInset : task9Frame.maxX-m.edgeInset
        m.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: Double(100-left),resetsAt: task9Now.addingTimeInterval(12600)))
        let v = PetView(model: m);v.time = 1000
        let world = grid.point(m.position),origin = size.windowOrigin(position: world,in: task9Frame,backingScale: scale)
        v.anchor = grid.point(CGPoint(x: world.x-origin.x,y: world.y-origin.y))
        let plateOrigin = v.batteryOrigin(now: date)
        let fills = QuotaBattery.geometry(left,at: plateOrigin,grid: grid,ink: QuotaBattery.ink,
            resets: QuotaBattery.resetText(m.quota!.fiveHour!,at: date),outline: QuotaBattery.outlineVisible(left,at: date))
        check(fills.allSatisfy { v.bounds.contains($0.rect) },"entire plate fits actual window at screen edges")
        check(origin.y+fills.map { $0.rect.minY }.min()! >= task9Frame.minY,"row stays above visible frame bottom / Dock")
        check(abs(plateOrigin.x+QuotaBattery.width(left,grid: grid)/2-v.anchor.x) <= 0.5,"row centred under feet within one pixel")
        let expected = task9Bitmap(Int(size.canvas.width*scale),Int(size.canvas.height*scale));expected.scaleBy(x: scale,y: scale)
        QuotaBattery.draw(m.quota,at: plateOrigin,cell: size.uiCell,now: date,in: expected,pixelScale: scale)
        let actual = task9Bitmap(expected.width,expected.height);actual.scaleBy(x: scale,y: scale)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: actual,flipped: false)
        v.draw(v.bounds,now: date);NSGraphicsContext.restoreGraphicsState()
        let want = expected.data!.assumingMemoryBound(to: UInt8.self),got = actual.data!.assumingMemoryBound(to: UInt8.self)
        var visible = 0,mismatch = 0
        for i in stride(from: 0,to: expected.height*expected.bytesPerRow,by: 4) where want[i+3] != 0 {
            visible += 1;if (0..<4).contains(where: { want[i+$0] != got[i+$0] }) { mismatch += 1 }
        }
        check(visible > 0 && mismatch == 0,"all actual plate pixels visible, including 2% and both blink phases")
    } } }
} }
// The meeting renderer has its own jump and props, independent of regular act motion.
var task9MeetingScenes = 0
for size in PetSize.allCases { for outfit in Outfit.allCases { for mood in PetState.allCases {
    let m = task9Model(size);m.chooseOutfit(outfit);m.state = mood
    let coordinator = MeetingCoordinator(directory: meetingTestRoot.appendingPathComponent("task9-render"))
    var epoch = 3000000000.0;coordinator.epochNow = { epoch };m.meeting = coordinator
    let v = PetView(model: m),grid = PixelGrid(cell: size.uiCell)
    for action in MeetingDrawing.actions {
        var c = meetingC,d = meetingD;c.scale = size.uiCell/8;d.scale = c.scale
        let plan = MeetingRules.plan(script: .init(lines: meetingScript.lines,action: action),situation: "both_idle",c: c,d: d,now: epoch)
        coordinator.setPreview(plan: plan)
        m.position.x = plan.x(.local);m.direction = plan.direction(.local)
        for step in 0...32 {
            epoch = plan.start+plan.actionAt+Double(step)/16
            v.time = 1000
            let airborne = MeetingDrawing.jumpHeight(plan: plan,now: epoch,cell: size.uiCell) > 0
            check(v.meetingAirborne == airborne && v.quotaPlateVisible == !airborne,"meeting jump hides row and restores it at landings")
            let pixels = v.sprite
            check(pixels.allSatisfy { v.bounds.contains($0.rect) },"meeting pixels fit: \(size) / \(outfit) / \(mood) / \(action) / \(step)")
            if v.quotaPlateVisible {
                let row = QuotaBattery.geometry(2,at: v.batteryOrigin(now: task9Now),grid: grid,ink: QuotaBattery.ink,resets: "03:30")
                    .reduce(CGRect.null) { $0.union($1.rect) }
                check(pixels.allSatisfy { !$0.rect.intersects(row) },"meeting sprite/props clear quota row")
            }
            task9MeetingScenes += 1
        }
    }
} } }
#if !DESK_PET
let task9Gallery = task9Bitmap(1920,1440);task9Gallery.scaleBy(x: 2,y: 2)
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: task9Gallery,flipped: false)
task9Gallery.setFillColor(PixelColor.color("EAF0F4"));task9Gallery.fill(CGRect(x: 0,y: 0,width: 960,height: 720))
task9Label("小水滴 · 八套水主题换装 · idle + sleeping · 原生 2× 像素",20,692,task9Gallery)
for (index,outfit) in Outfit.allCases.enumerated() {
    let x = CGFloat(index%4)*240,y = CGFloat(1-index/4)*336+8
    task9Gallery.setFillColor(PixelColor.color("FFFFFF"));task9Gallery.fill(CGRect(x: x+6,y: y,width: 228,height: 326))
    task9Label(outfit.title,x+16,y+303,task9Gallery)
    for (j,mood) in [PetState.idle,.sleeping].enumerated() {
        let m = task9Model();m.chooseOutfit(outfit);m.state = mood;m.actIndex = mood == .idle ? 1 : 0
        m.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: 5,resetsAt: nil));m.speech = "";m.speechUntil = 0
        let v = PetView(model: m);v.time = 1000.25;v.anchor = CGPoint(x: 120,y: 32)
        let layer = task9Bitmap(480,320);layer.scaleBy(x: 2,y: 2)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: layer,flipped: false)
        v.draw(v.bounds,now: task9Now);NSGraphicsContext.restoreGraphicsState()
        task9Gallery.draw(layer.makeImage()!,in: CGRect(x: x,y: y+CGFloat(1-j)*144,width: 240,height: 160))
    }
}
try NSBitmapImageRep(cgImage: task9Gallery.makeImage()!).representation(using: .png,properties: [:])!.write(to: task9Root.appendingPathComponent("gallery-outfits.png"))
NSGraphicsContext.restoreGraphicsState()
#endif
let task9Preview = task9Bitmap(1920,1120);task9Preview.scaleBy(x: 2,y: 2)
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: task9Preview,flipped: false)
task9Preview.setFillColor(PixelColor.color("EAF0F4"));task9Preview.fill(CGRect(x: 0,y: 0,width: 960,height: 560))
for (i,sample) in [(95,0),(30,0),(15,1),(2,0),(2,1),(0,1)].enumerated() {
    let x = CGFloat(i%3)*320,y = CGFloat(1-i/3)*260
    task9Preview.setFillColor(PixelColor.color("FFFFFF"));task9Preview.fill(CGRect(x: x+6,y: y+8,width: 308,height: 252))
    let m = task9Model();m.state = .idle;m.actIndex = 0
    m.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: Double(100-sample.0),resetsAt: task9Now.addingTimeInterval(12600)))
    let v = PetView(model: m);v.time = 1000;v.anchor = CGPoint(x: 160,y: 52)
    let layer = task9Bitmap(640,480);layer.scaleBy(x: 2,y: 2)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: layer,flipped: false)
    v.draw(v.bounds,now: task9Now.addingTimeInterval(Double(sample.1)));NSGraphicsContext.restoreGraphicsState()
    task9Preview.draw(layer.makeImage()!,in: CGRect(x: x,y: y,width: 320,height: 240))
    task9Label("\(sample.0)% · outline \(QuotaBattery.outlineVisible(sample.0,at: task9Now.addingTimeInterval(Double(sample.1))) ? "on" : "off")",x+16,y+230,task9Preview)
}
task9Label("Quota below feet · 95 / 30 / 15 / 2 / 0% · binary 1-second outline blink",18,535,task9Preview)
try NSBitmapImageRep(cgImage: task9Preview.makeImage()!).representation(using: .png,properties: [:])!.write(to: task9Root.appendingPathComponent("battery-preview.png"))
NSGraphicsContext.restoreGraphicsState()
print("PASS: \(checks-task9Start) Task 9 assertions; \(task9Scenes) regular + \(task9MeetingScenes) meeting scenes; quota colour/blink/visibility and actual raster checks")
