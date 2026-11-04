import AppKit

// Shared by the two sibling apps (DeskPet/PixelDrawing.swift is a relative symlink).
// Integer-cell designs keep whole-point edges. Fractional cells use whole device pixels.
// Animated offsets use half-cell pixel units.
struct PixelGrid {
    let cell: CGFloat
    var backingScale: CGFloat = 2
    var unit: CGFloat { (cell / 2 * backingScale).rounded() / backingScale }
    func pixel(_ value: CGFloat) -> CGFloat {
        let scale: CGFloat = cell == cell.rounded() ? 1 : backingScale
        return (value * scale).rounded() / scale
    }
    func snap(_ value: CGFloat) -> CGFloat { pixel((value / unit).rounded() * unit) }
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: snap(p.x), y: snap(p.y)) }
    func rect(_ r: CGRect) -> CGRect {
        let x = pixel(r.minX), y = pixel(r.minY)
        return CGRect(x: x, y: y, width: pixel(r.maxX) - x, height: pixel(r.maxY) - y)
    }
    func sourceRect(_ r: CGRect) -> CGRect {
        let q = rect(CGRect(x: r.minX * cell, y: r.minY * cell, width: r.width * cell, height: r.height * cell))
        return CGRect(x: q.minX / cell, y: q.minY / cell, width: q.width / cell, height: q.height / cell)
    }
}

struct PixelTransform {
    var a: CGFloat = 1, b: CGFloat = 0, c: CGFloat = 0, d: CGFloat = 1
    var tx: CGFloat = 0, ty: CGFloat = 0
    func applying(_ p: CGPoint) -> CGPoint { CGPoint(x: a*p.x + c*p.y + tx, y: b*p.x + d*p.y + ty) }
    func times(_ r: PixelTransform) -> PixelTransform {
        PixelTransform(a: a*r.a+c*r.b, b: b*r.a+d*r.b, c: a*r.c+c*r.d, d: b*r.c+d*r.d,
                       tx: a*r.tx+c*r.ty+tx, ty: b*r.tx+d*r.ty+ty)
    }
    static func translate(_ x: CGFloat, _ y: CGFloat) -> Self { Self(tx: x, ty: y) }
    static let mirror = Self(a: -1)
    static func rotate(_ degrees: CGFloat) -> Self {
        precondition(degrees.truncatingRemainder(dividingBy: 90) == 0, "Only quarter turns are pixel art")
        switch (Int(degrees / 90) % 4 + 4) % 4 {
        case 1: return Self(a: 0, b: 1, c: -1, d: 0)
        case 2: return Self(a: -1, d: -1)
        case 3: return Self(a: 0, b: -1, c: 1, d: 0)
        default: return Self()
        }
    }
}

struct Pose {
    var x: CGFloat = 0, y: CGFloat = 0
    var angle: CGFloat = 0, opacity: CGFloat = 1
    var mirrored = false
    func transform(around p: CGPoint, grid: PixelGrid) -> PixelTransform {
        precondition(opacity == 0 || opacity == 1, "Animation visibility must be binary")
        let pivot = CGPoint(x: grid.pixel(p.x * grid.cell) / grid.cell, y: grid.pixel(p.y * grid.cell) / grid.cell)
        let dx = grid.snap(x * grid.cell) / grid.cell, dy = grid.snap(y * grid.cell) / grid.cell
        return PixelTransform.translate(dx+pivot.x, dy+pivot.y).times(.rotate(angle))
            .times(mirrored ? .mirror : PixelTransform()).times(.translate(-pivot.x, -pivot.y))
    }
}

indirect enum PixelNode {
    case rect(CGRect, String, String)
    case group(String, [PixelNode])
    var bounds: CGRect {
        switch self {
        case .rect(let rect, _, _): return rect
        case .group(_, let nodes): return nodes.reduce(CGRect.null) { $0.union($1.bounds) }
        }
    }
}

enum PixelColor {
    // Colors are created once per hex; drawing asks for the same few dozen every frame.
    private static var cache: [String: CGColor] = [:]
    static func color(_ hex: String) -> CGColor {
        if let cached = cache[hex] { return cached }
        let rgb = UInt32(hex, radix: 16)!
        let color = CGColor(srgbRed: CGFloat((rgb>>16)&255)/255, green: CGFloat((rgb>>8)&255)/255,
                            blue: CGFloat(rgb&255)/255, alpha: 1)
        cache[hex] = color
        return color
    }
}

struct PixelPrimitive {
    let rect: CGRect
    let color: CGColor
    let interactive: Bool
    var path: CGPath { CGPath(rect: rect, transform: nil) }
    init(rect: CGRect, hex: String, interactive: Bool) {
        self.rect = rect; color = PixelColor.color(hex); self.interactive = interactive
    }
    init(rect: CGRect, color: CGColor, interactive: Bool) {
        self.rect = rect;self.color = color;self.interactive = interactive
    }
    static func transformed(_ rect: CGRect, by transform: PixelTransform, grid: PixelGrid,
                            hex: String, interactive: Bool) -> PixelPrimitive? {
        let r = grid.sourceRect(rect)
        let points = [CGPoint(x: r.minX,y: r.minY),CGPoint(x: r.maxX,y: r.minY),
                      CGPoint(x: r.maxX,y: r.maxY),CGPoint(x: r.minX,y: r.maxY)].map(transform.applying)
        let x = points.map(\.x), y = points.map(\.y)
        let box = grid.rect(CGRect(x: x.min()!, y: y.min()!, width: x.max()!-x.min()!, height: y.max()!-y.min()!))
        guard box.width > 0 && box.height > 0 else { return nil }
        return PixelPrimitive(rect: box, hex: hex, interactive: interactive)
    }
}

struct PixelFill {
    let rect: CGRect
    let hex: String
    func draw(in context: CGContext) {
        context.setFillColor(PixelColor.color(hex)); context.fill(rect)
    }
}

enum PixelDrawing {
    static func crisp(_ context: CGContext) {
        context.setShouldAntialias(false); context.setAllowsAntialiasing(false)
        context.setShouldSmoothFonts(false); context.setAllowsFontSmoothing(false)
        context.setShouldSubpixelPositionFonts(false); context.setShouldSubpixelQuantizeFonts(false)
    }
    static func shadow(at anchor: CGPoint, height: CGFloat, grid: PixelGrid, width: Int) -> [PixelFill] {
        guard height < 9 * grid.cell else { return [] }
        let p = grid.point(anchor), u = grid.unit
        return (0..<width).map { i in
            PixelFill(rect: CGRect(x: p.x + CGFloat(i-width/2)*u, y: grid.snap(p.y-height)-u,
                                   width: u, height: u), hex: "E0E0E0")
        }
    }
}

enum QuotaBattery {
    static let ink = "2B1D1A"
    static func fillHex(_ left: Int) -> String { left > 40 ? "5BD38A" : left > 15 ? "F2C14E" : "D8453B" }
    static func digitHex(_ left: Int) -> String { left > 40 ? "2E9E5B" : left > 15 ? "C9971C" : "D8453B" }
    static func timeHex(_ left: Int) -> String { left > 40 ? "6FB98F" : left > 15 ? "D9B35A" : "E58A84" }
    static func outlineVisible(_ left: Int, at now: Date) -> Bool {
        left >= 15 || Int(floor(now.timeIntervalSince1970)) % 2 == 0
    }
    static func dot(_ grid: PixelGrid) -> CGFloat { max(1 / grid.backingScale,grid.pixel(grid.cell / 4)) }
    static func height(_ grid: PixelGrid) -> CGFloat { 2 * grid.cell }
    // Keep the old bottom margin, raising both pets by one row and one UI unit.
    static func groundHeight(cell: CGFloat) -> CGFloat { 4.5 * cell }
    static func width(_ left: Int, grid: PixelGrid) -> CGFloat {
        4 * grid.cell + 2 * grid.unit + CGFloat(("\(left)%".count * 4 - 1) + 19) * dot(grid)
    }
    static func origin(under feet: CGPoint, left: Int, grid: PixelGrid) -> CGPoint {
        CGPoint(x: grid.pixel(feet.x-width(left,grid: grid)/2),y: grid.pixel(feet.y-2*grid.unit))
    }
    // World-space row geometry travels with the existing position heartbeat. Both apps
    // solve the same pair, including the available room in each actual window.
    struct Plate: Codable, Equatable {
        var feetX: CGFloat, width: CGFloat, minX: CGFloat, maxX: CGFloat, unit: CGFloat
        var valid: Bool {
            [feetX,width,minX,maxX,unit].allSatisfy(\.isFinite) &&
            width > 0 && unit > 0 && maxX-minX >= width
        }
        var centeredX: CGFloat { min(max((feetX-width/2).rounded(),minX),maxX-width) }
    }
    static func separatedX(_ own: Plate, from peer: Plate, firstAtTie: Bool) -> CGFloat {
        guard own.valid,peer.valid else { return own.centeredX }
        let first = own.feetX < peer.feetX || (own.feetX == peer.feetX && firstAtTie)
        let left = first ? own : peer, right = first ? peer : own
        var lx = left.centeredX, rx = right.centeredX
        let gap = left.unit+right.unit
        let overlap = lx+left.width+gap-rx
        if overlap > 0 {
            // Round away from the seam so whole-point placement cannot eat the gap.
            let shift = ceil(overlap/2)
            lx = max(left.minX,lx-shift)
            rx = min(right.maxX-right.width,rx+shift)
            // At an edge, give the unused half of the displacement to the other row.
            lx -= min(max(0,lx+left.width+gap-rx),lx-left.minX)
            rx += min(max(0,lx+left.width+gap-rx),right.maxX-right.width-rx)
        }
        return first ? lx : rx
    }
    static func resetText(_ five: QuotaWindow, at now: Date) -> String {
        guard let reset = five.resetsAt, reset > now else { return "--:--" }
        return resetFormatter.string(from: reset)
    }
    private static let resetFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static func segments(_ left: Int) -> Int { max(left > 0 ? 1 : 0, Int((CGFloat(left) / 100 * 4).rounded())) }
    static let glyphs: [Character: String] = [
        "0":"111101101101111", "1":"010110010010111", "2":"111001111100111", "3":"111001111001111",
        "4":"101101111001001", "5":"111100111001111", "6":"111100111101111", "7":"111001001001001",
        "8":"111101111101111", "9":"111101111001111", "%":"101001010100101", ":":"000010000010000", "-":"000000111000000"
    ]
    static func geometry(_ left: Int, at origin: CGPoint, grid: PixelGrid, ink: String,
                         resets: String? = nil, outline: Bool = true) -> [PixelFill] {
        let p = CGPoint(x: grid.pixel(origin.x),y: grid.pixel(origin.y)), cell = grid.cell
        func rect(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat,_ hex: String) -> PixelFill {
            PixelFill(rect: grid.rect(CGRect(x: p.x+x*cell,y: p.y-(y+h)*cell,width: w*cell,height: h*cell)),hex: hex)
        }
        // Same outline, cap and four separated charge cells as the panel reference.
        var result = outline ? [rect(0,0,3.6,2,ink),rect(3.6,0.5,0.4,1,ink)] : []
        result.append(rect(0.2,0.2,3.2,1.6,"FFFFFF"))
        for i in 0..<4 { result.append(rect(0.4+CGFloat(i)*0.8,0.4,0.6,1.2,i < segments(left) ? fillHex(left) : "E4E4E4")) }
        // The digits' dot is a quarter cell, so the number stays about as wide as the battery
        let d = dot(grid)
        // One compact row, with exactly one UI unit between battery, percentage and time.
        var x = grid.pixel(p.x+4*cell+grid.unit)
        let top = grid.pixel(p.y-cell+2.5*d)
        for (text,hex) in [("\(left)%",digitHex(left)),(resets ?? "--:--",timeHex(left))] {
            for (i,ch) in text.enumerated() {
                for (k,bit) in (glyphs[ch] ?? "").enumerated() where bit == "1" {
                    result.append(PixelFill(rect: CGRect(x: x+CGFloat(i*4+k%3)*d,y: top-CGFloat(k/3+1)*d,
                                                          width: d,height: d),hex: hex))
                }
            }
            x += CGFloat(text.count*4-1)*d+grid.unit
        }
        return result
    }
    static func draw(_ quota: QuotaSnapshot?, at origin: CGPoint, cell: CGFloat, now: Date, in context: CGContext,
                     pixelScale: CGFloat = 2, ink: String = "2B1D1A") {
        guard let five = quota?.fiveHour else { return }
        context.saveGState(); PixelDrawing.crisp(context)
        let left = five.remaining(at: now)
        for fill in geometry(left,at: origin,grid: PixelGrid(cell: cell,backingScale: pixelScale),
                             ink: ink,resets: resetText(five,at: now),outline: outlineVisible(left,at: now)) {
            fill.draw(in: context)
        }
        context.restoreGState()
    }
}

enum PixelBubble {
    struct Layout {
        let frame: CGRect
        let textRect: CGRect
        let detailRect: CGRect
        let fills: [PixelFill]
        let mainFont: CGFloat
        let detailFont: CGFloat
    }
    struct Cell: Hashable { let x: Int; let y: Int }
    static func paragraph(_ detail: Bool = false) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        p.lineBreakMode = detail ? .byTruncatingMiddle : .byCharWrapping
        return p
    }
    // Text measuring is the slowest part of a frame; the same line is measured every tick while it shows.
    private static var fonts: [String: NSFont] = [:]
    static func font(_ size: CGFloat,_ weight: NSFont.Weight) -> NSFont {
        let key = "\(size)|\(weight.rawValue)"
        if let cached = fonts[key] { return cached }
        let font = NSFont.systemFont(ofSize: size,weight: weight)
        fonts[key] = font
        return font
    }
    private static var measured: [String: CGRect] = [:]
    private static var detailWidths: [String: CGFloat] = [:]
    static func measure(_ text: String,unit u: CGFloat) -> CGRect {
        let key = "\(u)|\(text)"
        if let cached = measured[key] { return cached }
        let attributes: [NSAttributedString.Key: Any] = [.font: font(4*u,.medium),
                                                         .paragraphStyle: paragraph()]
        let rect = (text as NSString).boundingRect(with: NSSize(width: 66*u,height: 36*u),
            options: [.usesLineFragmentOrigin,.usesFontLeading],attributes: attributes)
        if measured.count > 200 { measured.removeAll() }
        measured[key] = rect
        return rect
    }
    static func measureDetail(_ detail: String,font: CGFloat) -> CGFloat {
        let key = "\(font)|\(detail)"
        if let cached = detailWidths[key] { return cached }
        let width = (detail as NSString).size(withAttributes: [.font: Self.font(font,.regular)]).width
        if detailWidths.count > 200 { detailWidths.removeAll() }
        detailWidths[key] = width
        return width
    }
    static func layout(text: String, detail: String, thinking: Bool, working: Bool, sprite: CGRect,
                       anchor: CGPoint, bounds: CGRect, worldY: CGFloat, screenTop: CGFloat,
                       reserveTop: CGFloat, grid: PixelGrid, ink: String, time: Double) -> Layout {
        let u = grid.unit, mainFont = 4*u, detailFont = 3*u
        func ceilUnit(_ x: CGFloat) -> CGFloat { ceil(x/u)*u }
        let measured = measure(text,unit: u)
        let textHeight = text.isEmpty ? 0 : min(36*u,ceilUnit(measured.height))
        let extra: CGFloat = thinking ? 4*u : working ? 5*u : 0
        let detailWidth = measureDetail(detail,font: detailFont)
        let width = min(72*u,max(20*u,ceilUnit(measured.width)+6*u,working ? ceilUnit(detailWidth)+6*u : 0))
        let height = max(10*u,textHeight+extra+6*u)
        let top = grid.snap(max(sprite.maxY,anchor.y+reserveTop))
        let below = worldY+top-anchor.y+4*u+height > screenTop-2*u
        let frame = CGRect(x: grid.snap(min(max(2*u,sprite.midX-width/2),bounds.maxX-width-2*u)),
                           y: grid.snap(min(max(4*u,below ? sprite.minY-height-4*u : top+4*u),bounds.maxY-height-4*u)),
                           width: width,height: height)
        let w = Int((width/u).rounded()), h = Int((height/u).rounded())
        var cells = Set<Cell>()
        for y in 0..<h { for x in 0..<w where !((y == 0 || y == h-1) && (x == 0 || x == w-1)) {
            cells.insert(Cell(x: x,y: y))
        } }
        let tail = min(max(3,Int(((sprite.midX-frame.minX)/u).rounded())),w-4)
        for row in 0..<3 { for dx in (-2+row)...(2-row) {
            cells.insert(Cell(x: tail+dx,y: below ? h+row : -1-row))
        } }
        var fills: [PixelFill] = []
        // Merge runs of identically coloured cells; the silhouette and outline stay one unit wide.
        for y in -3..<(h+3) {
            var start = 0, last: String? = nil
            func flush(_ end: Int) {
                if let color = last { fills.append(PixelFill(rect: CGRect(x: frame.minX+CGFloat(start)*u,
                    y: frame.minY+CGFloat(y)*u,width: CGFloat(end-start)*u,height: u),hex: color)) }
            }
            for x in 0...w {
                var color: String? = nil
                if cells.contains(Cell(x: x,y: y)) {
                    color = [(1,0),(-1,0),(0,1),(0,-1)].allSatisfy { dx,dy in cells.contains(Cell(x: x+dx,y: y+dy)) } ? "FFFFFF" : ink
                }
                if color != last { flush(x);start = x;last = color }
            }
            flush(w)
        }
        if thinking {
            let frameIndex = Int(max(0,time)*3)%4
            for i in 0..<3 where i <= frameIndex {
                fills.append(PixelFill(rect: CGRect(x: grid.snap(frame.midX)+CGFloat(i-1)*3*u,
                    y: frame.minY+3*u,width: u,height: u),hex: ink))
            }
        }
        return Layout(frame: frame,textRect: CGRect(x: frame.minX+3*u,y: frame.minY+3*u+extra,width: width-6*u,height: textHeight),
                      detailRect: CGRect(x: frame.minX+3*u,y: frame.minY+2*u,width: width-6*u,height: 5*u),
                      fills: fills,mainFont: mainFont,detailFont: detailFont)
    }
    static func draw(_ layout: Layout, text: String, detail: String, working: Bool, ink: String, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState(); context.saveGState()
        NSGraphicsContext.current?.shouldAntialias = false; PixelDrawing.crisp(context)
        for fill in layout.fills { fill.draw(in: context) }
        if !text.isEmpty {
            (text as NSString).draw(with: layout.textRect,options: [.usesLineFragmentOrigin,.usesFontLeading],
                attributes: [.font: font(layout.mainFont,.medium),
                             .foregroundColor: NSColor(cgColor: PixelColor.color(ink))!, .paragraphStyle: paragraph()])
        }
        if working {
            (detail as NSString).draw(in: layout.detailRect,withAttributes: [.font: font(layout.detailFont,.medium),
                .foregroundColor: NSColor(cgColor: PixelColor.color("777777"))!, .paragraphStyle: paragraph(true)])
        }
        context.restoreGState(); NSGraphicsContext.restoreGraphicsState()
    }
}

// How often a pet wakes up and redraws. Pixel art moves in whole steps, so only
// a held or falling pet needs 60 fps; idling at a low rate keeps the Mac cool.
enum FrameRate {
    // Strolling moves in 0.125 s steps, so two ticks per step are enough.
    static func interval(holding: Bool,airborne: Bool,interacting: Bool,walking: Bool,strolling: Bool = false,hovered: Bool,sleeping: Bool) -> TimeInterval {
        if holding || airborne { return 1.0 / 60 }
        if interacting || walking || hovered { return 1.0 / 20 }
        if strolling { return 1.0 / 16 }
        if sleeping { return 1.0 / 4 }
        return 1.0 / 10
    }
}

// Renders the view offscreen once per tick and reports the region that changed since the last frame.
// The window then shows `image` for just that region, so nothing is drawn twice or redrawn unchanged.
final class FrameGate {
    private var context: CGContext?
    private var last: [UInt8] = []
    private(set) var image: CGImage?

    func changed(size: NSSize,scale: CGFloat,draw: () -> Void) -> CGRect? {
        let w = max(1,Int((size.width*scale).rounded(.up))), h = max(1,Int((size.height*scale).rounded(.up)))
        if context?.width != w || context?.height != h {
            context = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,
                                space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.scaleBy(x: scale,y: scale)
            last = []
        }
        let full = CGRect(origin: .zero,size: size)
        guard let context = context, let data = context.data else { image = nil; return full }
        context.clear(full)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: false)
        draw()
        NSGraphicsContext.current = previous
        let row = context.bytesPerRow, count = row * h
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let dirty: CGRect? = last.count != count ? full : last.withUnsafeBytes { old -> CGRect? in
            let before = old.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let rows = (0..<h).filter { memcmp(before+$0*row,bytes+$0*row,row) != 0 }
            guard let top = rows.first, let bottom = rows.last else { return nil }
            var minX = w, maxX = -1
            for y in rows {
                let a = UnsafeRawPointer(before+y*row).assumingMemoryBound(to: UInt32.self)
                let b = UnsafeRawPointer(bytes+y*row).assumingMemoryBound(to: UInt32.self)
                var x = 0
                while x < min(minX,w) && a[x] == b[x] { x += 1 }
                minX = min(minX,x)
                var r = w-1
                while r > maxX && a[r] == b[r] { r -= 1 }
                maxX = max(maxX,r)
            }
            // Bitmap rows run top-down; the view is not flipped. Pad a point for rounding.
            return CGRect(x: CGFloat(minX)/scale-1,y: CGFloat(h-bottom-1)/scale-1,
                          width: CGFloat(maxX-minX+1)/scale+2,height: CGFloat(bottom-top+1)/scale+2)
        }
        guard dirty != nil else { return nil }
        last = Array(UnsafeBufferPointer(start: bytes,count: count))
        image = context.makeImage()
        return dirty
    }

    // Shows the last rendered frame; false when there is none yet and the view must draw itself.
    func present(in dirtyRect: NSRect,bounds: NSRect) -> Bool {
        guard let image = image, let context = NSGraphicsContext.current?.cgContext else { return false }
        context.saveGState()
        context.clip(to: dirtyRect)
        context.clear(dirtyRect)
        context.interpolationQuality = .none
        context.draw(image,in: bounds)
        context.restoreGState()
        return true
    }
}
