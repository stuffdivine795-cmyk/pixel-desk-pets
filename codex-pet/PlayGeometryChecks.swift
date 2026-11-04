// Native paired Task 12 render/geometry harness, run by both check.sh scripts.
let playGStart = geometryChecks
let playGPreviewTimes: [[Double]] = [ [0,0.75,1,1.75,2.5], [0.25,1.25,2.25,3.25,4.25], [0,0.5,1,2,4], [0,0.75,1.5,2,2.75], [0,0.5,1,2,2.75], [0,0.5,1.5,3,4.5], [0,2,3,3.5,4.25], [0.125,1.625,4.625,8.125,12], [0,0.5,1.5,2.5,4] ]
func playGPlan(_ kind: InteractionKind,_ c: MeetingPosition,_ d: MeetingPosition) -> MeetingPlan {
    var calls = 0
    let plan = InteractionPlanner.make(.init(kind: kind,subject: .claude),c: c,d: d,now: 1000,
        script: [.init(who: .claude,text: "一起玩一会"),.init(who: .codex,text: "小水滴来啦")],forced: true,index: { count in calls += 1;return calls%count })
    return plan
}
if geometryMode == "play-export" {
    let layers = geometryFolder.appendingPathComponent("play-layers")
    try FileManager.default.createDirectory(at: layers,withIntermediateDirectories: true)
    var metrics: [[String: Any]] = []
    for (row,k) in InteractionKind.allCases.enumerated() {
        for (col,sample) in playGPreviewTimes[row].enumerated() {
            let m = geometryModel();m.chooseSize(.medium);m.chooseOutfit(.none)
            m.state = k == .cheer ? .working : k == .comfort ? .error : .idle
            #if DESK_PET
            // Approved orange reference uses bare ears; preview this interaction's face clearly.
            m.chooseOutfit(.none)
            #endif
            var c = MeetingPosition(x: 170,y: m.floor,screen: "0,0,1440,900",facing: "right",mood: "idle",detail: "",busy: false,ts: 1000,stageBack: 56,stageFront: 56,walkSpeed: 32)
            var d = c;d.x = 330;d.stageFront = 52
            if k == .hide_seek { c.x = 400;d.x = 600;c.minX = 104;c.maxX = 1336;d.minX = 104;d.maxX = 1336 }
            var plan = playGPlan(k,c,d)
            // Make the preview show an actual decisive RPS round and a soccer miss.
            if k == .rps { plan.play?.rounds = [.init(claude: .rock,codex: .scissors)];plan.end = plan.actionAt+5 }
            if k == .soccer { plan.play?.miss = .codex }
            if k == .nap && col == 4 { plan.play?.releaseAt = plan.start+plan.actionAt+3.75 }
            let now = plan.start+plan.actionAt+sample
            m.position.x = plan.playTarget(geometryRole,now: now);m.position.y = m.floor;m.direction = plan.direction(geometryRole)
            let coordinator = MeetingCoordinator(directory: layers.appendingPathComponent("preview"));m.meeting = coordinator
            coordinator.epochNow = { now };coordinator.setPreview(plan: plan)
            let v = PetView(model: m);v.time = 1000;v.anchor = CGPoint(x: m.position.x,y: 40)
            if k == .hide_seek {
                // Crop an actual half-hidden sprite at the indicated screen edge, then bring it back.
                let edge: CGFloat = 120
                let shift = edge-(plan.play!.hideEdge)
                v.anchor.x += shift
                // Seeker can be far away; the preview preserves the actual world distance.
            }
            m.quota = QuotaSnapshot(fiveHour: QuotaWindow(used: k == .give_battery ? 85 : 40,resetsAt: nil))
            var peer = geometryRole == .claude ? d : c
            peer.x = plan.playTarget(geometryRole.other,now: now);peer.ts = now
            peer.screen = MeetingPosition.screenID(m.visibleFrame)
            peer.quotaPlate = .init(feetX: peer.x,width: QuotaBattery.width(k == .give_battery ? 15 : 60,grid: PixelGrid(cell: 8)),minX: peer.x-240,maxX: peer.x+240,unit: 4)
            coordinator.setPreviewPeer(peer)
            m.speech = plan.line(at: now,for: geometryRole)?.text ?? "";m.speechUntil = 1001
            let context = CGContext(data: nil,width: 1000,height: 520,bitsPerComponent: 8,bytesPerRow: 4000,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: 2,y: 2);PixelDrawing.crisp(context)
            if k == .hide_seek && sample < plan.play!.hideFor { context.clip(to: CGRect(x: 120,y: 0,width: 380,height: 260)) }
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: false)
            v.draw(v.bounds,now: Date(timeIntervalSince1970: now))
            NSGraphicsContext.restoreGraphicsState()
            let pixels = v.sprite
            metrics.append(["kind":k.rawValue,"frame":col,"pixels":try JSONSerialization.jsonObject(with: JSONEncoder().encode(pixels.map(GeometryRect.init)))])
            try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png,properties: [:])!.write(to: layers.appendingPathComponent("\(geometryRole.rawValue)-\(row)-\(col).png"))
        }
    }
    try JSONSerialization.data(withJSONObject: metrics).write(to: layers.appendingPathComponent("\(geometryRole.rawValue)-frames.json"))
    print("Exported native Task 12 preview layers (\(geometryRole.rawValue))")
}
if geometryMode == "play-verify" {
    let cAll = try JSONDecoder().decode([GeometryEntry].self,from: Data(contentsOf: geometryFolder.appendingPathComponent("claude.json")))
    let dAll = try JSONDecoder().decode([GeometryEntry].self,from: Data(contentsOf: geometryFolder.appendingPathComponent("codex.json")))
    func pos(_ e: GeometryEntry,_ x: CGFloat) -> MeetingPosition { .init(x: x,y: 36*e.scale,screen: "0,0,1800,1200",facing: "right",mood: e.mood,detail: "",busy: false,ts: 1000,scale: e.scale,minX: 140,maxX: 1660,stageBack: e.back,stageFront: e.front,walkSpeed: 32*e.scale,stageTop: e.right.filter(\.interactive).map { $0.y+$0.h }.max()) }
    func bounds(_ p: [PixelPrimitive]) -> CGRect { p.filter(\.interactive).reduce(CGRect.null) { $0.union($1.rect) } }
    func shifted(_ e: GeometryEntry,_ x: CGFloat,_ y: CGFloat,_ mirror: Bool) -> [PixelPrimitive] { (mirror ? e.left : e.right).map { g in var r = g.pixel.rect;r.origin.x += x;r.origin.y += y;return .init(rect: r,hex: g.color,interactive: g.interactive) } }
    // All 9 size pairs, both orders, every outfit pair, all discrete effect steps.
    for c in cAll.filter({ $0.mood == "idle" }) { for d in dAll.filter({ $0.mood == "idle" }) { for sign: CGFloat in [-1,1] {
        for k in InteractionKind.allCases {
            var plan = playGPlan(k,pos(c,700),pos(d,700+sign*240))
            if k == .rps { plan.play?.rounds = [.init(claude: .rock,codex: .rock),.init(claude: .scissors,codex: .scissors),.init(claude: .paper,codex: .rock)];plan.end = plan.actionAt+15 }
            let duration: Double = k == .nap || k == .cheer ? 5 : min(30,plan.end-plan.actionAt)
            for frame in -1...Int(ceil(duration*8)) {
                let now = plan.start+plan.actionAt+Double(frame)/8
                let cx = plan.playTarget(.claude,now: now),dx = plan.playTarget(.codex,now: now)
                var ce = c,de = d
                if k == .nap && frame >= 0 {
                    ce = cAll.first { $0.size == c.size && $0.outfit == c.outfit && $0.mood == "sleeping" }!
                    de = dAll.first { $0.size == d.size && $0.outfit == d.outfit && $0.mood == "sleeping" }!
                }
                let cb = shifted(ce,cx,plan.claudeY,plan.direction(.claude)<0),db = shifted(de,dx,plan.codexY,plan.direction(.codex)<0)
                let cp = InteractionDrawing.decorate(cb,role: .claude,plan: plan,now: now,anchor: CGPoint(x: cx,y: plan.claudeY),worldX: cx,cell: c.cell)
                let dp = InteractionDrawing.decorate(db,role: .codex,plan: plan,now: now,anchor: CGPoint(x: dx,y: plan.codexY),worldX: dx,cell: d.cell)
                let cr = bounds(cp),dr = bounds(dp)
                let boxesApart = cr.maxX <= dr.minX+0.01 || dr.maxX <= cr.minX+0.01
                let pixelsApart = boxesApart || (k == .comfort && !cp.filter(\.interactive).contains { a in dp.filter(\.interactive).contains { b in a.rect.intersection(b.rect).width > 0.01 && a.rect.intersection(b.rect).height > 0.01 } })
                geometryCheck(pixelsApart,"play sprites \(k) frame \(frame), \(c.size)/\(d.size) \(c.outfit)/\(d.outfit): \(cr) / \(dr)")
                for (x,other,e,role) in [(cx,dx,c,MeetingRole.claude),(dx,cx,d,.codex)] {
                    let width = QuotaBattery.width(100,grid: PixelGrid(cell: e.cell))
                    let own = QuotaBattery.Plate(feetX: x,width: width,minX: x-240*e.scale,maxX: x+240*e.scale,unit: 4*e.scale)
                    let otherE = role == .claude ? d : c
                    let peer = QuotaBattery.Plate(feetX: other,width: QuotaBattery.width(100,grid: PixelGrid(cell: otherE.cell)),minX: other-240*otherE.scale,maxX: other+240*otherE.scale,unit: 4*otherE.scale)
                    let a = QuotaBattery.separatedX(own,from: peer,firstAtTie: role == .claude),b = QuotaBattery.separatedX(peer,from: own,firstAtTie: role != .claude)
                    geometryCheck(a+own.width <= b+0.01 || b+peer.width <= a+0.01,"separated plates \(k)")
                }
                for pixel in cp+dp {
                    geometryCheck(pixel.color.alpha == 1 && pixel.rect.width > 0 && pixel.rect.height > 0 && [pixel.rect.minX,pixel.rect.minY,pixel.rect.maxX,pixel.rect.maxY].allSatisfy { abs($0*2-($0*2).rounded()) < 0.001 },"opaque, aligned positive rectangles \(k)")
                }
            }
        }
    } } }
    // Actual local view, every outfit/size/kind, ensures the shared decorations are wired in.
    for size in PetSize.allCases { for outfit in Outfit.allCases { for k in InteractionKind.allCases {
        let m = geometryModel();m.chooseSize(size);m.chooseOutfit(outfit)
        let coordinator = MeetingCoordinator(directory: geometryFolder.appendingPathComponent("native-play"));m.meeting = coordinator
        let plan = playGPlan(k,pos(cAll.first { $0.size == size.rawValue && $0.outfit == "none" && $0.mood == "idle" }!,500),pos(dAll.first { $0.size == size.rawValue && $0.outfit == "none" && $0.mood == "idle" }!,740))
        coordinator.setPreview(plan: plan);m.position.x = plan.x(geometryRole);m.direction = plan.direction(geometryRole)
        let v = PetView(model: m);v.anchor = CGPoint(x: 220,y: 40)
        for t in [0.0,0.125,0.75,1.5,3,4] {
            coordinator.epochNow = { plan.start+plan.actionAt+t }
            let sprite = v.sprite
            geometryCheck(!sprite.isEmpty && v.meetingSprite != nil,"actual PetView draws \(k)")
            for p in sprite { geometryCheck(p.color.alpha == 1,"actual \(k) opacity") }
        }
    } } }
    print("PASS: \(geometryChecks-playGStart) Task 12 paired frame/plate/pixel/native-view assertions (\(geometryRole.rawValue))")
}
if geometryMode == "play-compose" {
    let cols = 5,w = 2500,h = 2570
    let context = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    PixelDrawing.crisp(context);context.setFillColor(PixelColor.color("EAF0F4"));context.fill(CGRect(x: 0,y: 0,width: w,height: h))
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: false)
    for (row,k) in InteractionKind.allCases.enumerated() { for col in 0..<cols {
        let x = CGFloat(col*500),y = CGFloat(h-45-(row+1)*280)
        context.setFillColor(PixelColor.color("C7D0D9"));context.fill(CGRect(x: x+8,y: y+39,width: 484,height: 1))
        context.interpolationQuality = .none
        for role in MeetingRole.allCases {
            let data = try Data(contentsOf: geometryFolder.appendingPathComponent("play-layers/\(role.rawValue)-\(row)-\(col).png"))
            context.draw(NSBitmapImageRep(data: data)!.cgImage!,in: CGRect(x: x,y: y,width: 500,height: 260))
        }
        if k == .hide_seek { context.setFillColor(PixelColor.color("9AA0A6"));context.fill(CGRect(x: x+118,y: y,width: 2,height: 210)) }
        ("\(k.rawValue) · \(playGPreviewTimes[row][col]) s" as NSString).draw(at: CGPoint(x: x+12,y: y+255),withAttributes: [.font:NSFont.monospacedSystemFont(ofSize: 15,weight: .medium),.foregroundColor:NSColor.darkGray])
    } }
    ("TASK 12 · cards ①–⑧ · 中 · actual native sprites · five samples per kind (④ includes battery + fireworks)" as NSString).draw(at: CGPoint(x: 12,y: h-30),withAttributes: [.font:NSFont.systemFont(ofSize: 18),.foregroundColor:NSColor.darkGray])
    NSGraphicsContext.restoreGraphicsState()
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent().appendingPathComponent("desk-pet/play-preview.png")
    try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png,properties: [:])!.write(to: path)
    print("Rendered \(path.path)")
}
