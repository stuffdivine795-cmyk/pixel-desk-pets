// Appended to each app's existing offscreen program. No NSApplication or window is launched.
func wholePixel(_ value: CGFloat, _ scale: CGFloat) -> Bool { abs(value*scale-(value*scale).rounded()) < 0.00001 }
func verifyRect(_ r: CGRect, _ scale: CGFloat, _ message: String) {
    check(!r.isNull && r.width > 0 && r.height > 0, message+" positive rectangle")
    check([r.minX,r.minY,r.width,r.height].allSatisfy { wholePixel($0,scale) },message+" device pixels")
    #if DESK_PET
    check([r.minX,r.minY,r.width,r.height].allSatisfy { wholePixel($0,1) },message+" whole points")
    #endif
}
func verifyPrimitive(_ p: PixelPrimitive, _ scale: CGFloat) {
    check(p.color.alpha == 1,"every sprite cell is fully opaque")
    var r = CGRect.zero
    check(p.path.isRect(&r),"sprite paths contain axis-aligned rectangles only")
    verifyRect(r,scale,"sprite")
}
let pixelCheckStart = checks
let motionNames = ["look","blink","blink2","wave","sip","cast","bob","dance","stretch","jump","hop2","spin",
    "shake","squish","flat","legA","legB","tap","flail","swing","swing2","flick","page","pop","fall","drip",
    "rise","twinkle","ball","bulb","jug","orbit","snot","float","nod","sway","stir","horn","toss","snow","grow","bar"]
for name in motionNames { for stepCount in [1,2,3,4,6,8,10] { for frameIndex in 0...200 {
    let pose = PixelMotion.pose(name,time: Double(frameIndex)/199,duration: 1,steps: stepCount,once: true)
    check(pose.opacity == 0 || pose.opacity == 1,"no cross-fade: \(name)")
    check(pose.angle.truncatingRemainder(dividingBy: 90) == 0,"quarter turns only: \(name)")
    check(wholePixel(pose.x,2) && wholePixel(pose.y,2),"motion offsets use half cells: \(name)")
    let transform = pose.transform(around: CGPoint(x: 7.25,y: 6.4),grid: PixelGrid(cell: 8))
    check([transform.a,transform.b,transform.c,transform.d].allSatisfy { [-1,0,1].contains($0) },"no scale or arbitrary rotation")
} } }
#if DESK_PET
for i in 0...200 {
    let time = Double(i)/200
    let a = PixelMotion.pose("legA",time: time,duration: 0.5,steps: 8)
    let b = PixelMotion.pose("legB",time: time,duration: 0.5,steps: 8)
    check(a.opacity+b.opacity == 1,"exactly one walking leg set is visible at every phase")
}
check(Set((0..<60).map { PixelMotion.hornLength(time: Double($0)/100) }) == Set([CGFloat(2),4]),"horn has two explicit lengths")
check(Set((0..<300).map { PixelMotion.snotSize(time: Double($0)/100) }) == Set([CGFloat(0.5),1,1.5]),"snot has three explicit square sizes")
for size in PetSize.allCases { for (time,side) in [(0.1,CGFloat(0.5)),(1.1,CGFloat(1)),(2.1,CGFloat(1.5))] {
    let act = Act.all[.sleeping]!.first { $0.name == "鼻涕泡" }!
    let pixels = PixelSprite.primitives(mood: .sleeping,act: act,outfit: .none,elapsed: time,
        anchor: size.anchor,mirrored: false,walking: false,cell: size.cell)
    let nose = pixels.last!
    check(nose.color == PixelColor.color("BFE3F7"),"snot bubble is drawn in front of the arm")
    check(nose.rect.size == CGSize(width: side*size.cell,height: side*size.cell),"three visible snot rectangle sizes")
} }
#endif
for (pct,expected) in [(0,0),(1,1),(8,1),(15,1),(30,1),(40,2),(60,2),(63,3),(100,4)] {
    check(QuotaBattery.segments(pct) == expected,"four-segment battery rounding \(pct)")
}
let expectedGlyphs = ["111101101101111","010110010010111","111001111100111","111001111001111",
    "101101111001001","111100111001111","111100111101111","111001001001001","111101111101111","111101111001111","101001010100101"]
for (i,ch) in "0123456789%".enumerated() { check(QuotaBattery.glyphs[ch] == expectedGlyphs[i],"exact 3x5 glyph \(ch)") }

let pixelTimes = [0.0,0.031,0.127,0.249,0.251,0.374,0.501,0.749,0.917,1.001,1.337,1.55,2.567,3.219,5.8,8.9]
for scale: CGFloat in [1,2] { for size in PetSize.allCases {
    let uiGrid = PixelGrid(cell: size.uiCell,backingScale: scale)
    for mood in PetState.allCases {
        #if DESK_PET
        for outfit in Outfit.allCases { for act in Act.all[mood]!+Act.costumeActs(outfit: outfit,mood: mood) {
            for time in pixelTimes { for mirrored in [false,true] {
                let pixels = PixelSprite.primitives(mood: mood,act: act,outfit: outfit,elapsed: time,
                    anchor: CGPoint(x: size.anchor.x+0.37,y: size.anchor.y+0.23),mirrored: mirrored,walking: true,
                    squash: 0.37,pixelScale: scale,cell: size.cell)
                for pixel in pixels { verifyPrimitive(pixel,scale) }
            } }
        } }
        #else
        for act in Act.all[mood]!+(Act.signatures[mood] ?? []) { for time in pixelTimes { for mirrored in [false,true] {
            let pixels = PixelSprite.primitives(mood: mood,act: act,elapsed: time,
                anchor: CGPoint(x: size.anchor.x+0.37,y: size.anchor.y+0.23),mirrored: mirrored,walking: true,
                squash: 0.37,pixelScale: scale,cell: size.cell)
            for pixel in pixels { verifyPrimitive(pixel,scale) }
        } } }
        #endif
    }
    for trick in Trick.allCases { for time in pixelTimes where time < trick.duration {
        #if DESK_PET
        let pixels = PixelSprite.primitives(mood: .idle,act: Act.all[.idle]![0],outfit: .witch,elapsed: time,
            anchor: size.anchor,mirrored: false,walking: true,trick: trick,trickTime: time,pixelScale: scale,cell: size.cell)
        #else
        let pixels = PixelSprite.primitives(mood: .idle,act: Act.all[.idle]![0],elapsed: time,
            anchor: size.anchor,mirrored: false,walking: true,trick: trick,trickTime: time,pixelScale: scale,cell: size.cell)
        #endif
        for pixel in pixels { verifyPrimitive(pixel,scale) }
    } }
    for pct in [0,1,8,15,16,30,40,41,60,100] {
        let fills = QuotaBattery.geometry(pct,at: CGPoint(x: 123.47,y: 85.23),grid: uiGrid,ink: "2B1D1A")
        check(fills[3..<7].filter { $0.hex == QuotaBattery.fillHex(pct) }.count == QuotaBattery.segments(pct),"four separated lit segments")
        check(fills[3..<7].filter { $0.hex == "E4E4E4" }.count == 4-QuotaBattery.segments(pct),"unlit cells are light grey")
        for fill in fills { verifyRect(fill.rect,scale,"battery") }
        let dot = max(1/uiGrid.backingScale,uiGrid.pixel(uiGrid.cell/4))
        for fill in fills.dropFirst(7) { check(fill.rect.size == CGSize(width: dot,height: dot),"a quarter cell per font dot") }
    }
    for height: CGFloat in [0,0.137,10.37,75.1] {
        for fill in PixelDrawing.shadow(at: size.anchor,height: height,grid: uiGrid,width: 28) { verifyRect(fill.rect,scale,"shadow") }
        let position = CGPoint(x: 500.137,y: 100+height)
        let origin = size.windowOrigin(position: position,in: frame,backingScale: scale)
        check(wholePixel(origin.x,scale) && wholePixel(origin.y,scale),"window travel on device pixels")
        check(abs(origin.x/uiGrid.unit-(origin.x/uiGrid.unit).rounded()) < 0.00001,"window travel uses UI pixel units")
    }
} }

func pixelBitmap(_ width: Int,_ height: Int) -> CGContext {
    CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
let pixelLines = SpeechLines(url: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("pixel-test-no-lines.json"))
for size in PetSize.allCases { for scale: CGFloat in [1,2] { for atTop in [false,true] { for mood in [PetState.working,.thinking] {
    let m = PetModel(frame: frame,lines: pixelLines,now: 1000,preferences: MemoryDefaults()); m.chooseSize(size)
    m.state = mood; m.actIndex = 0; m.actSince = 1000
    m.position.y = atTop ? frame.maxY-100*size.scale : m.floor
    m.speech = String(repeating: "认真检查，每一步都算数。",count: atTop ? 6 : 1);m.speechUntil = 1005
    m.detail = "Read · 正在核对像素";m.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: 40,resetsAt: nil))
    let view = PetView(model: m); view.time = 1000.127
    let layer = pixelBitmap(Int(size.canvas.width*scale),Int(size.canvas.height*scale));layer.scaleBy(x: scale,y: scale)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: layer,flipped: false)
    view.draw(view.bounds)
    let box = view.sprite.reduce(CGRect.null) { $0.union($1.rect) }
    let layout = view.bubbleLayout(above: box)!
    for fill in layout.fills { verifyRect(fill.rect,scale,"bubble") }
    check(view.bounds.contains(layout.frame),"speech bubble fits at both screen edges")
    check(layout.mainFont.truncatingRemainder(dividingBy: size.uiCell/2) == 0,"main font is a UI unit multiple")
    check(layout.detailFont < layout.mainFont,"tool line is smaller")
    // Full NSView raster, including Chinese text: all alpha bytes must be 0 or 255.
    let bytes = layer.data!.assumingMemoryBound(to: UInt8.self)
    var fractionalAlpha = 0
    for y in 0..<layer.height { for x in 0..<layer.width {
        let alpha = bytes[y*layer.bytesPerRow+x*4+3]
        if alpha != 0 && alpha != 255 { fractionalAlpha += 1 }
    } }
    check(fractionalAlpha == 0,"actual NSView including CJK text has binary alpha")
    NSGraphicsContext.restoreGraphicsState()
    // An opaque white bubble could hide antialiased glyph alpha. Test the very same
    // text drawing on transparency as well, with only the frame fills omitted.
    let textLayer = pixelBitmap(layer.width,layer.height);textLayer.scaleBy(x: scale,y: scale)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: textLayer,flipped: false)
    let textOnly = PixelBubble.Layout(frame: layout.frame,textRect: layout.textRect,detailRect: layout.detailRect,
                                     fills: [],mainFont: layout.mainFont,detailFont: layout.detailFont)
    PixelBubble.draw(textOnly,text: m.speech,detail: m.detail,working: mood == .working,ink: "1E2A44",in: textLayer)
    let textBytes = textLayer.data!.assumingMemoryBound(to: UInt8.self)
    var textPixels = 0, blendedTextPixels = 0
    for y in 0..<textLayer.height { for x in 0..<textLayer.width {
        let alpha = textBytes[y*textLayer.bytesPerRow+x*4+3]
        if alpha == 255 { textPixels += 1 }
        else if alpha != 0 { blendedTextPixels += 1 }
    } }
    check(textPixels > 0 && blendedTextPixels == 0,"CJK and tool glyphs have no antialiased edges on transparency")
    NSGraphicsContext.restoreGraphicsState()
} } } }

// Close-up rendered directly at a 2x backing scale, with four exact requested quotas.
let preview = pixelBitmap(1920,1920); preview.scaleBy(x: 2,y: 2)
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: preview,flipped: false)
preview.setFillColor(PixelColor.color("EAF0F4"));preview.fill(CGRect(x: 0,y: 0,width: 960,height: 960))
for (i,pct) in [100,60,30,8].enumerated() {
    let m = PetModel(frame: frame,lines: pixelLines,now: 1000,preferences: MemoryDefaults());m.chooseSize(.medium)
    m.state = .working;m.actIndex = 0;m.actSince = 1000;m.speech = "认真检查，每一步都算数。";m.speechUntil = 1005
    m.detail = "Read · 正在核对像素"
    m.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: Double(100-pct),resetsAt: nil),sevenDay: QuotaWindow(used: 70,resetsAt: nil))
    let view = PetView(model: m);view.anchor = CGPoint(x: 240,y: 80);view.time = 1000.27
    let layer = pixelBitmap(960,960);layer.scaleBy(x: 2,y: 2)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: layer,flipped: false)
    view.draw(view.bounds);NSGraphicsContext.restoreGraphicsState()
    let x = CGFloat(i%2)*480,y = CGFloat(1-i/2)*480
    preview.setFillColor(PixelColor.color("FFFFFF"));preview.fill(CGRect(x: x+8,y: y+8,width: 464,height: 464))
    preview.interpolationQuality = .none
    preview.draw(layer.makeImage()!,in: CGRect(x: x,y: y,width: 480,height: 480))
    PixelDrawing.crisp(preview)
    ("\(pct)% · sprite \(m.size.cell) pt / UI \(m.size.uiCell) pt / 2×" as NSString).draw(at: CGPoint(x: x+24,y: y+432),
        withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 16,weight: .medium),.foregroundColor: NSColor.darkGray])
}
let previewURL = URL(fileURLWithPath: CommandLine.arguments[2]).deletingLastPathComponent().appendingPathComponent("bubble-preview.png")
try NSBitmapImageRep(cgImage: preview.makeImage()!).representation(using: .png,properties: [:])!.write(to: previewURL)
NSGraphicsContext.restoreGraphicsState()
print("PASS: \(checks-pixelCheckStart) pixel-art assertions (all sizes; 1x/2x; intermediate frames, CJK raster); rendered \(previewURL.path)")
