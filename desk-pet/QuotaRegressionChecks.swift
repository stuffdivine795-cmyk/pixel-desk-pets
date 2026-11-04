// Task 7: real state-file decoding followed by the actual view's offscreen drawing.
// Keep time fixed: these fixtures must still exercise 2% after the reset date passes.
let quotaCheckStart = checks
let quotaNow = LogDate.parse("2026-11-02T12:00:00Z")!
let quotaFixture = #"{"state":"working","detail":"Bash","outfit":"witch","quota":{"five_hour":{"used":98,"resetsAt":"2026-11-02T14:30:00.000Z"},"seven_day":{"used":13,"resetsAt":"2026-11-09T07:00:00.000Z"}},"ts":1793628000}"#
let quotaFile = testRoot.appendingPathComponent("quota-regression-state.json")
let quotaReader = StateReader(url: quotaFile)
var quotaRenders = 0
for (dateIndex,json) in [quotaFixture,quotaFixture.replacingOccurrences(of: ".000Z",with: "Z")].enumerated() {
    try Data(json.utf8).write(to: quotaFile,options: .atomic)
    guard let signal = quotaReader.poll() else { fatalError("quota fixture was not read") }
    check(signal.state == .working && signal.detail == "Bash" && signal.outfit == "witch","exact Task 7 state")
    check(signal.quota?.fiveHour?.used == 98 && signal.quota?.sevenDay?.used == 13,"both quota windows decode")
    check(signal.quota?.fiveHour?.resetsAt == LogDate.parse("2026-11-02T14:30:00Z"),"reset date with/without fractional seconds")
    check(signal.quota?.fiveHour?.remaining(at: quotaNow) == 2,"98% used means 2% left")
    check(signal.quota?.sevenDay?.remaining(at: quotaNow) == 87,"weekly remaining quota")
    check(signal.quota?.fiveHour?.remaining(at: LogDate.parse("2026-11-02T14:30:00Z")!) == 100,"reset boundary")
    for size in PetSize.allCases { for scale: CGFloat in [1,2] { for edge in 0..<3 { for speaking in [false,true] {
        let m = PetModel(frame: frame,lines: pixelLines,now: 1000,preferences: MemoryDefaults())
        m.chooseSize(size);m.receive(signal,now: 1000);m.actIndex = 0
        m.speech = speaking ? "认真做好每一小步，马上就好！" : "";m.speechUntil = speaking ? 1005 : 0
        m.position.x = edge == 0 ? frame.midX : edge == 1 ? frame.minX+m.edgeInset : frame.maxX-m.edgeInset
        m.position.y = m.floor
        let v = PetView(model: m);v.time = 1001
        let origin = size.windowOrigin(position: m.position,in: frame,backingScale: scale)
        v.anchor = PixelGrid(cell: size.cell,backingScale: scale).point(CGPoint(x: m.position.x-origin.x,y: m.position.y-origin.y))
        let fills = QuotaBattery.geometry(2,at: v.batteryOrigin(now: quotaNow),grid: PixelGrid(cell: size.cell,backingScale: scale),ink: "2B1D1A")
        check(fills.allSatisfy { v.bounds.contains($0.rect) },"battery and 2% label fit actual window at every size/edge")
        check(fills[3..<7].filter { $0.hex == "D8453B" }.count == 1,"2% has one red segment")
        let width = Int(size.canvas.width*scale),height = Int(size.canvas.height*scale)
        let expected = pixelBitmap(width,height);expected.scaleBy(x: scale,y: scale)
        QuotaBattery.draw(signal.quota,at: v.batteryOrigin(now: quotaNow),cell: size.cell,now: quotaNow,in: expected,pixelScale: scale)
        let actual = pixelBitmap(width,height);actual.scaleBy(x: scale,y: scale)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: actual,flipped: false)
        v.draw(v.bounds,now: quotaNow)
        NSGraphicsContext.restoreGraphicsState()
        let want = expected.data!.assumingMemoryBound(to: UInt8.self),got = actual.data!.assumingMemoryBound(to: UInt8.self)
        var painted = 0,mismatched = 0
        for i in stride(from: 0,to: height*expected.bytesPerRow,by: 4) where want[i+3] != 0 {
            painted += 1
            if (0..<4).contains(where: { want[i+$0] != got[i+$0] }) { mismatched += 1 }
        }
        check(painted > 0 && mismatched == 0,"actual PetView keeps every battery/label pixel visible under the feet and working bubble")
        if dateIndex == 0 && size == .medium && scale == 2 && edge == 0 && speaking {
            try NSBitmapImageRep(cgImage: actual.makeImage()!).representation(using: .png,properties: [:])!
                .write(to: testRoot.appendingPathComponent("quota-2-percent.png"))
        }
        quotaRenders += 1
    } } } }
}
print("PASS: \(checks-quotaCheckStart) Task 7 quota assertions; \(quotaRenders) actual view renders; fractional/plain dates, all sizes, 1x/2x, screen edges, working bubbles; 2% battery visible")
