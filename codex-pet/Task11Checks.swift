// Appended to the independent native pair harness. Each executable exports its
// actual PetView row in identical scenarios; verification joins the two exports.
struct NativeQuotaRow: Codable {
    var id: String, visible: Bool
    var row: CGRect, window: CGRect
    var feetX: CGFloat, centeredX: CGFloat, unit: CGFloat
}
let quotaPairFrame = CGRect(x: -240,y: 30,width: 1800,height: 1200)
let quotaPairNow = Date(timeIntervalSince1970: 2000000000)
func quotaPairPosition(_ size: PetSize,_ role: MeetingRole,_ x: CGFloat,_ left: Int) -> MeetingPosition {
    let grid = PixelGrid(cell: size.uiCell),feetX = grid.snap(x)
    let feet = CGPoint(x: feetX,y: quotaPairFrame.minY+QuotaBattery.groundHeight(cell: size.uiCell))
    let origin = size.windowOrigin(position: feet,in: quotaPairFrame)
    let inset = 13*size.uiCell*(role == .claude ? 1 : 0.75)
    return MeetingPosition(x: feetX,y: feet.y,screen: MeetingPosition.screenID(quotaPairFrame),
        facing: "right",mood: "idle",detail: "",quota5h: left,busy: false,ts: quotaPairNow.timeIntervalSince1970,
        scale: size.uiCell/8,minX: quotaPairFrame.minX+inset,maxX: quotaPairFrame.maxX-inset,
        stageBack: (role == .claude ? 56 : 52)*size.uiCell/8,
        stageFront: (role == .claude ? 56 : 52)*size.uiCell/8,
        quotaPlate: .init(feetX: feetX,width: QuotaBattery.width(left,grid: grid),minX: origin.x,
                          maxX: origin.x+size.canvas.width,unit: grid.unit))
}
func quotaPairView(_ own: MeetingPosition,_ peer: MeetingPosition,size: PetSize,
                   plan: MeetingPlan? = nil) -> PetView {
    let m = geometryModel();m.visibleFrame = quotaPairFrame;m.chooseSize(size);m.chooseOutfit(.none)
    m.state = .idle;m.actIndex = 0;m.actSince = 1000;m.position = CGPoint(x: own.x,y: own.y)
    m.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: Double(100-own.quota5h!),resetsAt: nil))
    let coordinator = MeetingCoordinator(directory: geometryFolder.appendingPathComponent("quota-preview"))
    coordinator.epochNow = { quotaPairNow.timeIntervalSince1970 }
    coordinator.setPreviewPeer(peer)
    if let plan = plan { coordinator.setPreview(plan: plan);m.direction = plan.direction(.local) }
    m.meeting = coordinator
    let v = PetView(model: m),grid = PixelGrid(cell: size.uiCell)
    let origin = size.windowOrigin(position: m.position,in: quotaPairFrame)
    v.anchor = grid.point(CGPoint(x: own.x-origin.x,y: own.y-origin.y));v.time = 1000
    return v
}
func quotaPairRow(_ v: PetView,id: String) -> NativeQuotaRow {
    let m = v.model,grid = PixelGrid(cell: m.size.uiCell)
    let world = CGPoint(x: grid.snap(m.position.x)-v.anchor.x,y: grid.snap(m.position.y)-v.anchor.y)
    let left = m.quota!.fiveHour!.remaining(at: quotaPairNow)
    let fills = QuotaBattery.geometry(left,at: v.batteryOrigin(now: quotaPairNow),grid: grid,
        ink: QuotaBattery.ink,resets: "03:40")
    let row = fills.reduce(CGRect.null) { $0.union($1.rect) }
    geometryCheck(fills.allSatisfy { v.bounds.contains($0.rect) },"native row fits its actual window: \(id)")
    geometryCheck(fills.allSatisfy { p in [p.rect.minX,p.rect.minY,p.rect.maxX,p.rect.maxY].allSatisfy { $0 == $0.rounded() } },
                  "shifted quota pixels remain whole points at 1x and 2x: \(id)")
    if v.quotaPlateVisible {
        geometryCheck(v.sprite.allSatisfy { !$0.rect.intersects(row) },"shifted row clears its sprite/props: \(id)")
    }
    let published = m.meeting!.snapshot(m,now: quotaPairNow.timeIntervalSince1970).quotaPlate!
    geometryCheck(published.minX == world.x && published.maxX == world.x+v.bounds.width,
                  "published window matches native placement: \(id)")
    geometryCheck(published.width == row.width,"published width includes the reset time: \(id)")
    return .init(id: id,visible: v.quotaPlateVisible,row: row.offsetBy(dx: world.x,dy: world.y),
        window: v.bounds.offsetBy(dx: world.x,dy: world.y),feetX: grid.snap(m.position.x),
        centeredX: published.centeredX,unit: grid.unit)
}
if geometryMode == "rows" {
    var rows: [NativeQuotaRow] = []
    // One-, two-, three-digit percentages, zero quota, all mixed-size combinations.
    for cs in PetSize.allCases { for ds in PetSize.allCases {
        for (cq,dq) in [(2,78),(78,2),(100,100),(0,9),(9,100)] {
            for edge in 0..<3 {
                let center: CGFloat = edge == 0 ? 660 : edge == 1 ? -120 : 1440
                func pair(_ distance: CGFloat) -> (MeetingPosition,MeetingPosition) {
                    func clamp(_ x: CGFloat,_ size: PetSize,_ role: MeetingRole) -> CGFloat {
                        let inset = 13*size.uiCell*(role == .claude ? 1 : 0.75)
                        return min(max(x,quotaPairFrame.minX+inset),quotaPairFrame.maxX-inset)
                    }
                    return (quotaPairPosition(cs,.claude,clamp(center-distance/2,cs,.claude),cq),
                            quotaPairPosition(ds,.codex,clamp(center+distance/2,ds,.codex),dq))
                }
                let key = "\(cs.rawValue)/\(ds.rawValue)/\(cq)/\(dq)/\(edge)"
                // Passing in both directions, coincident feet, and the threshold neighborhood.
                for distance: CGFloat in [-260,-160,-121,-112,-108,-100,-80,-40,-8,-1,0,1,8,40,80,100,108,112,121,160,260] {
                    let (c,d) = pair(distance),own = geometryRole == .claude ? c : d,peer = geometryRole == .claude ? d : c
                    let v = quotaPairView(own,peer,size: geometryRole == .claude ? cs : ds)
                    rows.append(quotaPairRow(v,id: "pass/\(key)/\(distance)"))
                }
                for sign: CGFloat in [-1,1] { for action in MeetingDrawing.actions {
                    let (c,d) = pair(sign*80)
                    let plan = MeetingRules.plan(script: .init(lines: [.init(who: .claude,text: "test"),
                        .init(who: .codex,text: "test")],action: action),situation: "both_idle",c: c,d: d,now: quotaPairNow.timeIntervalSince1970)
                    var cp = quotaPairPosition(cs,.claude,plan.claudeX,cq)
                    var dp = quotaPairPosition(ds,.codex,plan.codexX,dq)
                    cp.busy = true;dp.busy = true
                    let v = quotaPairView(geometryRole == .claude ? cp : dp,geometryRole == .claude ? dp : cp,
                        size: geometryRole == .claude ? cs : ds,plan: plan)
                    // All 1/8 s frames, conversation, midpoint, and just before the end.
                    for frame in -1...16 {
                        let seconds = frame < 0 ? 1 : plan.actionAt+min(1.999,Double(frame)/8)
                        v.model.meeting!.epochNow = { plan.start+seconds }
                        // Keep the peer heartbeat fresh, as it is during a running meeting.
                        var freshPeer = geometryRole == .claude ? dp : cp;freshPeer.ts = plan.start+seconds
                        v.model.meeting!.setPreviewPeer(freshPeer)
                        let row = quotaPairRow(v,id: "meet/\(key)/\(sign)/\(action)/\(frame)")
                        geometryCheck(row.visible == !v.meetingAirborne,"only airborne meeting frames hide the row")
                        rows.append(row)
                    }
                } }
            }
        }
    } }
    try JSONEncoder().encode(rows).write(to: geometryFolder.appendingPathComponent("\(geometryRole.rawValue)-rows.json"))
    print("PASS: \(geometryChecks) native quota placement assertions; exported \(rows.count) rows (\(geometryRole.rawValue))")
} else if geometryMode == "verify" {
    let start = geometryChecks
    let c = try JSONDecoder().decode([NativeQuotaRow].self,from: Data(contentsOf: geometryFolder.appendingPathComponent("claude-rows.json")))
    let d = try JSONDecoder().decode([NativeQuotaRow].self,from: Data(contentsOf: geometryFolder.appendingPathComponent("codex-rows.json")))
    geometryCheck(c.count == d.count && !c.isEmpty,"both native row exports contain the same scenarios")
    var baselineCollisions = 0, shifted = 0
    for (a,b) in zip(c,d) {
        geometryCheck(a.id == b.id,"pair scenario IDs match")
        geometryCheck(a.window.contains(a.row) && b.window.contains(b.row),"both rows stay inside their windows: \(a.id)")
        if a.visible && b.visible {
            let first = a.feetX <= b.feetX, l = first ? a : b,r = first ? b : a
            geometryCheck(l.row.maxX+l.unit+r.unit <= r.row.minX,"two native rows keep two units of clearance: \(a.id), \(a.row) / \(b.row)")
            geometryCheck(!a.row.intersects(b.row),"actual row rectangles never overlap: \(a.id)")
            if l.centeredX+l.row.width+l.unit+r.unit > r.centeredX { baselineCollisions += 1 }
            if a.row.minX != a.centeredX || b.row.minX != b.centeredX { shifted += 1 }
        }
    }
    geometryCheck(baselineCollisions > 100 && shifted == baselineCollisions,"fixtures expose the old centered-row collision and move exactly the affected pairs")
    // Exact threshold, symmetric displacement, and saturated edge behavior independently
    // of action timing. Swapping the caller must return the other half of the same pair.
    let a = QuotaBattery.Plate(feetX: 500,width: 100,minX: 260,maxX: 740,unit: 4)
    for distance: CGFloat in [0,1,80,107,108,109,160] {
        var b = a;b.feetX += distance;b.minX += distance;b.maxX += distance
        let ax = QuotaBattery.separatedX(a,from: b,firstAtTie: true)
        let bx = QuotaBattery.separatedX(b,from: a,firstAtTie: false)
        geometryCheck(ax+100+8 <= bx,"threshold and coincident-feet separation")
        geometryCheck(abs((a.centeredX-ax)-(bx-b.centeredX)) <= 1,"symmetric to one whole point")
        geometryCheck(distance < 108 || (ax == a.centeredX && bx == b.centeredX),"distant rows remain centered")
    }
    // The actual view must ignore unrelated, stale or absent peers; old heartbeat
    // JSON without the optional new geometry must continue to decode.
    let own = quotaPairPosition(.medium,.local,500,78)
    var peer = quotaPairPosition(.medium,geometryRole.other,500,2)
    let v = quotaPairView(own,peer,size: .medium),meeting = v.model.meeting!
    let centered = QuotaBattery.origin(under: v.anchor,left: 78,grid: PixelGrid(cell: 8))
    geometryCheck(v.batteryOrigin(now: quotaPairNow) != centered,"native PetView uses nearby peer geometry")
    for mutation in 0..<7 {
        peer = quotaPairPosition(.medium,geometryRole.other,500,2)
        switch mutation {
        case 0: peer.ts -= 3.01
        case 1: peer.screen = "other screen"
        case 2: peer.quotaPlate = nil
        case 3: peer.grounded = false
        case 4: peer.dragging = true
        case 5: peer.trick = true
        default: peer.quotaPlate!.width = .nan
        }
        meeting.setPreviewPeer(peer)
        geometryCheck(v.batteryOrigin(now: quotaPairNow) == centered,"native row ignores unusable peer \(mutation)")
    }
    meeting.setPreviewPeer(nil)
    geometryCheck(v.batteryOrigin(now: quotaPairNow) == centered,"row recenters when peer disappears")
    let legacy = #"{"x":500,"y":36,"screen":"test","facing":"right","mood":"idle","detail":"","busy":false,"ts":2000000000,"grounded":true,"dragging":false,"trick":false,"scale":1}"#
    let decodedLegacy = try JSONDecoder().decode(MeetingPosition.self,from: Data(legacy.utf8))
    geometryCheck(decodedLegacy.quotaPlate == nil,"old heartbeat format remains readable")
    // Exercise the real file transport between animation ticks, inside the old
    // 0.5 s polling interval. Readiness is disabled so this only tests movement.
    let transport = geometryFolder.appendingPathComponent("quota-transport-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: transport) }
    let mover = geometryModel(),observer = geometryModel()
    let sender = MeetingCoordinator(role: .claude,directory: transport)
    let receiver = MeetingCoordinator(role: .codex,directory: transport)
    mover.meeting = sender;observer.meeting = receiver
    var tick = quotaPairNow.timeIntervalSince1970
    sender.epochNow = { tick };receiver.epochNow = { tick }
    for model in [mover,observer] {
        model.quiet = true;model.dragging = true
        model.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: 22,resetsAt: nil))
    }
    mover.position.x = 500;observer.position.x = 900
    mover.step(dt: 0,now: 1000);observer.step(dt: 0,now: 1000)
    tick += 1.0/60;mover.position.x = 540
    mover.step(dt: 0,now: 1000.01);observer.step(dt: 0,now: 1000.01)
    let transmitted = try JSONDecoder().decode(MeetingPosition.self,from: Data(contentsOf: sender.ownURL))
    geometryCheck(transmitted.x == PixelGrid(cell: mover.size.uiCell).snap(mover.position.x),"motion publishes the new feet before the next draw")
    geometryCheck(receiver.peer?.quotaPlate == transmitted.quotaPlate,"next animation tick receives fresh quota geometry before the old poll deadline")
    print("PASS: \(geometryChecks-start) Task 11 pair-row assertions; \(c.count) native pairs; \(baselineCollisions) former centered collisions (\(geometryRole.rawValue))")
}
