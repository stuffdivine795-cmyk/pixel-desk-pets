// Additional offscreen quota checks; the DeskPet source/build/check files remain separate.
var checks = 0
func check(_ condition: @autoclosure () -> Bool,_ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n",stderr);exit(1) };checks += 1
}
final class MemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?,forKey key: String) { values[key] = value }
}
let date = LogDate.parse("2026-11-02T12:00:00Z")!
func decode(_ text: String) -> PetSignal? { try? JSONDecoder().decode(PetSignal.self,from: Data(text.utf8)) }
let signal = decode(#"{"state":"working","detail":"Bash","quota":{"five_hour":{"used":57,"resetsAt":"2026-11-02T14:30:00Z"},"seven_day":{"used":70,"resetsAt":"2026-11-06T09:21:00.000Z"}}}"#)!
check(signal.quota?.fiveHour?.remaining(at: date) == 43,"Claude five_hour used decodes")
check(signal.quota?.sevenDay?.remaining(at: date) == 30,"Claude seven_day/fractional ISO date decodes")
check(signal.quota?.fiveHour?.remaining(at: date.addingTimeInterval(3*3600)) == 100,"passed reset is 100 percent left")
for text in [#"{"state":"idle"}"#,#"{"state":"idle","quota":{}}"#,#"{"state":"idle","quota":{"five_hour":{}}}"#,
             #"{"state":"idle","quota":{"five_hour":{"used":"bad"},"seven_day":{"used":5}}}"#,
             #"{"state":"idle","quota":null}"#] {
    let parsed = decode(text)
    check(parsed?.state == .idle && parsed?.quota?.fiveHour == nil,"missing/malformed optional window keeps state and hides battery")
}
let missingReset = decode(#"{"state":"idle","quota":{"five_hour":{"used":36}}}"#)!
check(missingReset.quota?.fiveHour?.remaining(at: date) == 64,"missing reset still shows known quota")
check(missingReset.quota?.menuTitles(at: date).first?.contains("重置时间未知") == true,"missing reset not invented")
let missingURL = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent(".build/checks/no-custom-lines.json")
let lines = SpeechLines(url: missingURL);lines.reloadIfChanged()
let model = PetModel(frame: CGRect(x: 0,y: 0,width: 1440,height: 900),lines: lines,now: 1000,preferences: MemoryDefaults())
model.receive(signal,now: 1001)
check(model.state == .working && model.quota == signal.quota,"quota reaches model")
model.receive(decode(#"{"state":"working","quota":{"five_hour":{"used":85}}}"#)!,now: 1002)
check(model.state == .working && model.quota?.fiveHour?.remaining(at: date) == 15,"quota-only update with unchanged state")
let view = PetView(model: model)
let menu = view.contextMenu()
check(menu.item(withTitle: "换装") != nil,"existing costume menu retained")
let info = menu.items.filter { $0.title.hasPrefix("5 小时：") || $0.title.hasPrefix("每周：") }
check(info.count == 1 && info.allSatisfy { !$0.isEnabled && $0.action == nil },"disabled quota information in actual view menu")
model.receive(.idle,now: 1003)
check(model.quota == nil,"removed quota clears battery")
let context = CGContext(data: nil,width: 1440,height: 1130,bitsPerComponent: 8,bytesPerRow: 1440*4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: false)
context.setFillColor(CGColor(srgbRed: 0.97,green: 0.94,blue: 0.90,alpha: 1));context.fill(CGRect(x: 0,y: 0,width: 1440,height: 1130))
func label(_ text: String,_ x: CGFloat,_ y: CGFloat,_ font: CGFloat = 15) {
    (text as NSString).draw(at: CGPoint(x: x,y: y),withAttributes: [.font:NSFont.systemFont(ofSize: font),.foregroundColor:NSColor.darkGray])
}
label("像素小橘 · 原有六种心情 + 额度电池",24,1083,25)
label("小橘 8 pt 像素 / 两者共用 8 pt 电池单位 · 演示 43% / 40% / 15% / 已重置 100% / 缺周额度 / 无额度",24,1054)
let quota = signal.quota!
for (i,mood) in PetState.allCases.enumerated() {
    let origin = CGPoint(x: (i%3)*480,y: 540-(i/3)*440)
    let m = PetModel(frame: CGRect(x: 0,y: 0,width: 1440,height: 900),lines: lines,now: 1000,preferences: MemoryDefaults())
    m.state = mood;m.actIndex = 0;m.actSince = 1000;m.speech = "";m.speechUntil = 0
    let left = [43,40,15,100,64,-1][i]
    if i == 3 {
        m.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: 99,resetsAt: Date.distantPast),sevenDay: quota.sevenDay)
    } else if i == 4 {
        m.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: Double(100-left),resetsAt: nil))
    } else if left >= 0 {
        m.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: Double(100-left),resetsAt: Date.distantFuture),sevenDay: quota.sevenDay)
    }
    let v = PetView(model: m);v.anchor = CGPoint(x: 210,y: 115);v.time = 1000.4
    // PetView clears with .copy. Render into a transparent layer, then composite it
    // onto the card so the gallery has the same readable background as a desktop.
    let layer = CGContext(data: nil,width: 480,height: 480,bitsPerComponent: 8,bytesPerRow: 480*4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: layer,flipped: false)
    v.draw(v.bounds)
    NSGraphicsContext.restoreGraphicsState()
    context.saveGState();context.translateBy(x: origin.x,y: origin.y)
    context.setFillColor(CGColor(gray: 1,alpha: 0.85));context.fill(CGRect(x: 8,y: 8,width: 464,height: 424))
    context.draw(layer.makeImage()!,in: CGRect(x: 0,y: 0,width: 480,height: 480))
    label("\(mood.rawValue) · \(left < 0 ? "无额度：电池隐藏" : "剩 \(left)%")",24,393,18)
    context.restoreGState()
}
label("使用实际 PetView 离屏绘制；所有原有装扮和动作保留。示例额度不写入真实 state.json。",24,44)
let image = NSBitmapImageRep(cgImage: context.makeImage()!)
try image.representation(using: .png,properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
NSGraphicsContext.restoreGraphicsState()
print("PASS: \(checks) additional DeskPet quota assertions; gallery-battery.png rendered")
