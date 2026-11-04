// Compiled against each app's real model/view, without either GUI entry point.
let pairRoot = URL(fileURLWithPath: CommandLine.arguments.last!,isDirectory: true)
#if DESK_PET
let pairName = "desk"
let pairInk = "2B1D1A"
#else
let pairName = "codex"
let pairInk = "1E2A44"
#endif
let pairFrame = CGRect(x: 0,y: 0,width: 1440,height: 900)
let pairLines = SpeechLines(url: pairRoot.appendingPathComponent("pair-no-custom-lines.json"))
var pairMetrics: [String: [String: Any]] = [:]
for pairSize in PetSize.allCases {
    let pairModel = PetModel(frame: pairFrame,lines: pairLines,now: 1000,preferences: MemoryDefaults())
    pairModel.chooseSize(pairSize)
    #if DESK_PET
    pairModel.chooseOutfit(.witch)
    #endif
    pairModel.state = .idle;pairModel.actIndex = 0;pairModel.actSince = 1000;pairModel.quiet = true
    pairModel.speech = "今天也要元气满满！";pairModel.speechUntil = 1005
    pairModel.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: 40,resetsAt: nil))
    let pairView = PetView(model: pairModel);pairView.time = 1000
    // Reproduce placeWindow() to check the actual world ground, not just a staged image.
    let pairGrid = PixelGrid(cell: pairSize.uiCell,backingScale: 2)
    let pairPosition = pairGrid.point(pairModel.position)
    let pairOrigin = pairSize.windowOrigin(position: pairPosition,in: pairFrame,backingScale: 2)
    pairView.anchor = pairGrid.point(CGPoint(x: pairPosition.x-pairOrigin.x,y: pairPosition.y-pairOrigin.y))
    let pairSprite = pairView.sprite.reduce(CGRect.null) { $0.union($1.rect) }
    let pairBubble = pairView.bubbleLayout(above: pairSprite)!
    let pairBattery = QuotaBattery.geometry(60,at: pairView.batteryOrigin,grid: pairGrid,ink: QuotaBattery.ink)
    let pairBatteryBase = pairBattery[0].rect
    let pairBatteryRects = pairBattery.map { fill in
        [Double(fill.rect.minX-pairBatteryBase.minX),Double(fill.rect.minY-pairBatteryBase.minY),
         Double(fill.rect.width),Double(fill.rect.height)]
    }
    check(abs(pairOrigin.y+pairSprite.minY-pairModel.floor) < 0.001,"idle feet meet the model's world ground")
    check(pairView.bounds.contains(pairSprite),"paired idle sprite fits its window")
    check(pairBattery.allSatisfy { pairView.bounds.contains($0.rect) },"full-size battery and digits fit under the feet")
    pairMetrics[pairSize.rawValue] = [
        "ground":Double(pairOrigin.y+pairSprite.minY),"height":Double(pairSprite.height),
        "bubbleSize":[Double(pairBubble.frame.width),Double(pairBubble.frame.height)],
        "fonts":[Double(pairBubble.mainFont),Double(pairBubble.detailFont)],"battery":pairBatteryRects
    ]
    if pairSize == .medium {
        // 2x device pixels, with both actual views translated to the same ground.
        pairView.anchor = CGPoint(x: 240,y: 64)
        let pairLayer = CGContext(data: nil,width: 960,height: 600,bitsPerComponent: 8,bytesPerRow: 960*4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pairLayer.scaleBy(x: 2,y: 2)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: pairLayer,flipped: false)
        pairView.draw(pairView.bounds)
        NSGraphicsContext.restoreGraphicsState()
        try NSBitmapImageRep(cgImage: pairLayer.makeImage()!).representation(using: .png,properties: [:])!
            .write(to: pairRoot.appendingPathComponent("pair-\(pairName).png"))
    }
}
try JSONSerialization.data(withJSONObject: pairMetrics,options: [.prettyPrinted,.sortedKeys])
    .write(to: pairRoot.appendingPathComponent("pair-\(pairName).json"))

#if DESK_PET
let pairCodex = try JSONSerialization.jsonObject(with: Data(contentsOf: pairRoot.appendingPathComponent("pair-codex.json"))) as! [String: [String: Any]]
for pairSize in PetSize.allCases {
    let drop = pairCodex[pairSize.rawValue]!, critter = pairMetrics[pairSize.rawValue]!
    for key in ["ground","bubbleSize","fonts","battery"] {
        check((drop[key] as! NSObject).isEqual(critter[key]),"both apps have identical \(key) at \(pairSize.title)")
    }
    let dropHeight = drop["height"] as! Double, critterHeight = critter["height"] as! Double
    check(abs(dropHeight/critterHeight-1) < 0.15,"requested cells give comparable total idle heights including the witch hat")
    print("Pair \(pairSize.title): drop \(dropHeight) pt, critter + hat \(critterHeight) pt; ground/UI/battery match")
}
let pairCanvas = CGContext(data: nil,width: 1920,height: 680,bitsPerComponent: 8,bytesPerRow: 1920*4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
pairCanvas.scaleBy(x: 2,y: 2)
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: pairCanvas,flipped: false)
PixelDrawing.crisp(pairCanvas)
pairCanvas.setFillColor(PixelColor.color("EAF0F4"));pairCanvas.fill(CGRect(x: 0,y: 0,width: 960,height: 340))
pairCanvas.setFillColor(PixelColor.color("C7D0D9"));pairCanvas.fill(CGRect(x: 20,y: 79,width: 920,height: 1))
for (i,name) in ["codex","desk"].enumerated() {
    let layer = NSBitmapImageRep(data: try Data(contentsOf: pairRoot.appendingPathComponent("pair-\(name).png")))!.cgImage!
    pairCanvas.interpolationQuality = .none
    pairCanvas.draw(layer,in: CGRect(x: CGFloat(i)*480,y: 16,width: 480,height: 300))
    let title = i == 0 ? "CodexPet · 中 · 6 pt cells" : "DeskPet · 中 · 8 pt cells + witch hat"
    (title as NSString).draw(at: CGPoint(x: CGFloat(i)*480+40,y: 310),withAttributes: [
        .font:NSFont.monospacedSystemFont(ofSize: 15,weight: .medium),.foregroundColor:NSColor.darkGray])
}
("Idle at the same ground · UI 8 pt / quota dots 2 pt in both apps · rendered at 2×" as NSString)
    .draw(at: CGPoint(x: 40,y: 24),withAttributes: [.font:NSFont.monospacedSystemFont(ofSize: 13,weight: .regular),
                                                .foregroundColor:NSColor.darkGray])
let pairOutput = pairRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("pair-preview.png")
try NSBitmapImageRep(cgImage: pairCanvas.makeImage()!).representation(using: .png,properties: [:])!.write(to: pairOutput)
NSGraphicsContext.restoreGraphicsState()
print("PASS: cross-app size/ground/UI checks; rendered \(pairOutput.path)")
#endif
