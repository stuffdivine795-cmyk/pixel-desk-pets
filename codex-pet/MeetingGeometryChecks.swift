// Separate native harness: each app exports its real geometry, then checks the pair together.
import AppKit
final class GeometryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?,forKey key: String) { values[key] = value }
}
struct GeometryRect: Codable, Equatable {
    var x: CGFloat,y: CGFloat,w: CGFloat,h: CGFloat,color: String,interactive: Bool
    init(_ p: PixelPrimitive) {
        x = p.rect.minX;y = p.rect.minY;w = p.rect.width;h = p.rect.height;interactive = p.interactive
        let c = p.color.components!
        color = String(format: "%02X%02X%02X",Int((c[0]*255).rounded()),Int((c[1]*255).rounded()),Int((c[2]*255).rounded()))
    }
    var pixel: PixelPrimitive { .init(rect: CGRect(x: x,y: y,width: w,height: h),hex: color,interactive: interactive) }
}
struct GeometryEntry: Codable {
    var size: String,outfit: String,mood: String,scale: CGFloat,cell: CGFloat
    var back: CGFloat,front: CGFloat
    var right: [GeometryRect],left: [GeometryRect]
}
let geometryFolder = URL(fileURLWithPath: CommandLine.arguments[2],isDirectory: true)
try FileManager.default.createDirectory(at: geometryFolder,withIntermediateDirectories: true)
let geometryRole = MeetingRole.local
let geometryMode = CommandLine.arguments[1]
var geometryChecks = 0
func geometryCheck(_ ok: @autoclosure () -> Bool,_ why: String) {
    if !ok() { fputs("FAIL: pair geometry: \(why)\n",stderr);exit(1) };geometryChecks += 1
}
func geometryModel() -> PetModel {
    PetModel(frame: CGRect(x: 0,y: 0,width: 1800,height: 1200),lines: SpeechLines(url: geometryFolder.appendingPathComponent("no-lines.json")),now: 1000,preferences: GeometryDefaults())
}
if geometryMode == "export" {
    var entries: [GeometryEntry] = []
    for size in PetSize.allCases { for outfit in Outfit.allCases { for mood in PetState.allCases {
        let m = geometryModel();m.chooseSize(size);m.chooseOutfit(outfit);m.state = mood
        func base(_ mirror: Bool) -> [GeometryRect] {
            #if DESK_PET
            return PixelSprite.primitives(mood: mood,act: Act(name: "会面"),outfit: outfit,elapsed: 0,anchor: .zero,mirrored: mirror,walking: false,cell: size.cell,meeting: true).map(GeometryRect.init)
            #else
            return PixelSprite.primitives(mood: mood,act: Act(name: "会面"),elapsed: 0,anchor: .zero,mirrored: mirror,walking: false,cell: size.cell,meeting: true,outfit: outfit).map(GeometryRect.init)
            #endif
        }
        entries.append(.init(size: size.rawValue,outfit: outfit.rawValue,mood: mood.rawValue,scale: size.uiCell/8,cell: size.uiCell,back: m.meetingExtents.back,front: m.meetingExtents.front,right: base(false),left: base(true)))
    } } }
    try JSONEncoder().encode(entries).write(to: geometryFolder.appendingPathComponent("\(geometryRole.rawValue).json"))
} else if geometryMode == "verify" {
    let claude = try JSONDecoder().decode([GeometryEntry].self,from: Data(contentsOf: geometryFolder.appendingPathComponent("claude.json")))
    let codex = try JSONDecoder().decode([GeometryEntry].self,from: Data(contentsOf: geometryFolder.appendingPathComponent("codex.json")))
    func position(_ e: GeometryEntry,_ x: CGFloat) -> MeetingPosition {
        MeetingPosition(x: x,y: 36*e.scale,screen: "pair",facing: "right",mood: e.mood,detail: "",busy: false,ts: 1000,
                        scale: e.scale,stageBack: e.back,stageFront: e.front,walkSpeed: 33*e.scale)
    }
    func translated(_ pixels: [GeometryRect],x: CGFloat,y: CGFloat) -> [PixelPrimitive] {
        pixels.map { p in var r = p.pixel.rect;r.origin.x += x;r.origin.y += y;return .init(rect: r,hex: p.color,interactive: p.interactive) }
    }
    func bounds(_ pixels: [PixelPrimitive]) -> CGRect { pixels.filter(\.interactive).reduce(CGRect.null) { $0.union($1.rect) } }
    // All outfit pairs, all 9 size combinations, both orders, every discrete 1/8-second action frame.
    for c in claude.filter({ $0.mood == "idle" }) { for d in codex.filter({ $0.mood == "idle" }) { for sign: CGFloat in [-1,1] {
        for action in MeetingDrawing.actions {
            let cp = position(c,500),dp = position(d,500+sign*80)
            let plan = MeetingRules.plan(script: .init(lines: (0..<4).map { .init(who: $0%2 == 0 ? .claude : .codex,text: "test") },action: action),situation: "both_idle",c: cp,d: dp,now: 1000)
            let cx = PixelGrid(cell: c.cell).snap(plan.claudeX),dx = PixelGrid(cell: d.cell).snap(plan.codexX)
            geometryCheck(cx == plan.claudeX && dx == plan.codexX,"stage survives the actual window-placement grids")
            let cb = translated(sign > 0 ? c.right : c.left,x: cx,y: plan.claudeY)
            let db = translated(sign > 0 ? d.left : d.right,x: dx,y: plan.codexY)
            for frame in -1...16 {
                let time = frame < 0 ? plan.start+1 : plan.start+plan.actionAt+Double(frame)/8
                let cs = MeetingDrawing.decorate(cb,role: .claude,plan: plan,now: time,anchor: CGPoint(x: plan.claudeX,y: plan.claudeY),worldX: plan.claudeX,cell: c.cell)
                let ds = MeetingDrawing.decorate(db,role: .codex,plan: plan,now: time,anchor: CGPoint(x: plan.codexX,y: plan.codexY),worldX: plan.codexX,cell: d.cell)
                let cr = bounds(cs),dr = bounds(ds)
                geometryCheck(sign > 0 ? cr.maxX <= dr.minX : dr.maxX <= cr.minX,"\(action) frame \(frame), \(c.size)/\(d.size), \(c.outfit)/\(d.outfit), sign \(sign): \(cr) / \(dr)")
                // Even contact actions may only reach across with the new arms. Original bodies stay apart.
                geometryCheck(sign > 0 ? bounds(cb).maxX < bounds(db).minX : bounds(db).maxX < bounds(cb).minX,"bodies never intersect")
                if frame == -1 {
                    let gap = sign > 0 ? dr.minX-cr.maxX : cr.minX-dr.maxX
                    geometryCheck(gap >= 4*c.scale+4*d.scale-0.01,"conversation leaves two pixel units")
                }
            }
        }
    } } }
    // The real local PetView must render action drawings at +1 s, for every mood/size/outfit.
    for size in PetSize.allCases { for outfit in Outfit.allCases { for mood in PetState.allCases { for action in MeetingDrawing.actions {
        let m = geometryModel();m.chooseSize(size);m.chooseOutfit(outfit);m.state = mood
        let coordinator = MeetingCoordinator(directory: geometryFolder.appendingPathComponent("preview"));m.meeting = coordinator
        let c = claude.first { $0.size == size.rawValue && $0.outfit == (geometryRole == .claude ? outfit.rawValue : "none") && $0.mood == mood.rawValue }!
        let d = codex.first { $0.size == size.rawValue && $0.outfit == (geometryRole == .codex ? outfit.rawValue : "none") && $0.mood == mood.rawValue }!
        let plan = MeetingRules.plan(script: .init(lines: (0..<4).map { .init(who: $0%2 == 0 ? .claude : .codex,text: "test") },action: action),situation: "both_idle",c: position(c,500),d: position(d,580),now: 1000)
        coordinator.setPreview(plan: plan);m.position.x = plan.x(geometryRole);m.direction = plan.direction(geometryRole)
        let v = PetView(model: m);v.time = 1000
        var now = plan.start+1;coordinator.epochNow = { now }
        let idle = v.sprite.map(GeometryRect.init)
        for t in [0.0,0.125,0.5,1,1.5,1.875,1.999] {
            now = plan.start+plan.actionAt+t
            geometryCheck(plan.action(at: now) == action,"\(action) remains selected at \(t)s for its full two-second duration")
            let pixels = v.sprite.map(GeometryRect.init)
            geometryCheck(pixels != idle,"both pets draw \(action), including actionAt+1 s (\(mood.rawValue))")
        }
        now = plan.start+plan.end
        geometryCheck(plan.action(at: now) == nil,"action ends at the shared deadline")
    } } } }
    print("PASS: \(geometryChecks) actual cross-app sprite-box and full-action assertions (\(geometryRole.rawValue))")
}
