import AppKit

// One state machine, picker, line reader and pixel-effects renderer for both pets.
enum LandingTrick: String, CaseIterable {
    case light, parachute, balloons, trampoline, jetpack, box, broom, party_balloons
    case splash, cloud, bubble, umbrella, lotus, duck, ice
    static func general(_ role: MeetingRole,height: CGFloat) -> [Self] {
        role == .claude ? [.parachute,.balloons,.trampoline,.box] + (height >= 400 ? [.jetpack] : []) : [.splash,.cloud,.bubble]
    }
    static func signature(_ role: MeetingRole,outfit: String) -> Self? {
        if role == .claude { return ["witch": Self.broom,"party": .party_balloons][outfit] }
        return ["umbrella": Self.umbrella,"lotus": .lotus,"duck": .duck,"ice": .ice][outfit]
    }
    static func pick(role: MeetingRole,height: CGFloat,outfit: String,last: Self?,
                     roll: () -> Double = { Double.random(in: 0..<1) },
                     index: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Self? {
        guard height >= 80 else { return nil }
        guard height >= 220 else { return .light }
        // Never repeat, including an outfit trick. 70% preference applies when it is eligible.
        if let special = signature(role,outfit: outfit),special != last,roll() < 0.7 { return special }
        let pool = general(role,height: height).filter { $0 != last }
        return pool[index(pool.count)]
    }
    var protected: Bool { self != .light && self != .splash }
    var settleDuration: Double {
        switch self {
        case .light: return 0.4
        case .balloons,.party_balloons: return 1.5
        case .trampoline: return 1.6
        case .box: return 1.1
        case .splash: return 1.2
        case .ice: return 1.2
        default: return 0.4
        }
    }
}

struct LandingRun {
    let kind: LandingTrick
    let started: Double
    let height: CGFloat
    let originX: CGFloat
    let direction: CGFloat
    var landedAt: Double?
    var distance: CGFloat = 0
    func deployed(at now: Double) -> Bool { now-started >= 0.125 }
    func age(at now: Double) -> Double { max(0,now-(landedAt ?? started)) }
}

final class LandingLines {
    let url: URL
    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/pet/landing-lines.json")) { self.url = url }
    func line(role: MeetingRole,kind: LandingTrick,landed: Bool) -> String {
        if let data = try? Data(contentsOf: url),data.count < 262144,
           let file = try? JSONDecoder().decode([String: [String: [String: [String]]]].self,from: data),
           let choices = file[role.rawValue]?[kind.rawValue]?[landed ? "land" : "start"]?.filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
           let text = choices.randomElement() { return String(text.prefix(84)) }
        let names: [LandingTrick: String] = [.parachute:"降落伞",.balloons:"气球",.trampoline:"弹床",.jetpack:"喷气背包",.box:"纸箱",.broom:"扫帚",.party_balloons:"派对气球",.splash:"小水花",.cloud:"小雨云",.bubble:"泡泡",.umbrella:"小雨伞",.lotus:"荷叶",.duck:"小鸭",.ice:"小冰块",.light:"轻轻跳"]
        return landed ? ["稳稳落地啦","轻轻落下来"].randomElement()! : "\(names[kind]!)接住我"
    }
}

extension PetModel {
    var landingScale: CGFloat { size.uiCell/8 }
    var landingAirborne: Bool {
        guard let run = landing,run.landedAt != nil else { return landing != nil }
        return LandingDrawing.bounce(run,now: landingClock,unit: PixelGrid(cell: size.cell).unit) > 0
    }
    func beginDrag(now: Double) {
        dragging = true;landing = nil;trick = nil;landingSquash = 0;velocityY = 0
        speech = "";speechUntil = 0
        meeting?.dragged(self)
    }
    func beginLanding(height: CGFloat,now: Double) {
        landingClock = now;trick = nil;landingSquash = 0
        guard let kind = LandingTrick.pick(role: .local,height: height/landingScale,outfit: outfit.rawValue,last: lastLanding) else { landing = nil;return }
        landing = LandingRun(kind: kind,started: now,height: max(1,position.y-floor),originX: position.x,direction: direction)
        if kind != .light {
            lastLanding = kind
            speech = landingLines.line(role: .local,kind: kind,landed: false);speechUntil = now+2
        }
    }
    // Returns true while the landing owns physics (including its short settling effect).
    func stepLanding(dt: Double,now: Double) -> Bool {
        landingClock = now
        if dragging { landing = nil;return false }
        guard var run = landing else { return false }
        if let landed = run.landedAt {
            if now-landed >= run.kind.settleDuration { landing = nil;return false }
            if run.kind == .ice {
                let progress = min(1,CGFloat((now-landed)/0.75))
                position.x = (run.originX+run.direction*60*landingScale*progress).rounded();constrainX()
            }
            velocityY = 0
            return true
        }
        if run.kind.protected && run.deployed(at: now) {
            // Accumulate subpixel distance, then move by whole points: no rounding-speed bias.
            velocityY = -115*landingScale
            run.distance += -velocityY*CGFloat(dt)
            let step = run.distance.rounded(.down);run.distance -= step
            position.y -= step
        } else {
            velocityY -= 1600*CGFloat(dt)
            run.distance += -velocityY*CGFloat(dt)
            let step = run.distance.rounded(.down);run.distance -= step
            position.y -= step
        }
        if run.kind == .lotus || run.kind == .cloud {
            let progress = min(1,max(0,1-(position.y-floor)/run.height))
            let drift: CGFloat = run.kind == .lotus ? 60 : 24
            position.x = (run.originX+run.direction*drift*landingScale*progress).rounded();constrainX()
        }
        if position.y <= floor {
            position.y = floor;velocityY = 0;run.landedAt = now
            // Ice starts its slide at its contact position, not at the drag's original X.
            if run.kind == .ice {
                run = LandingRun(kind: run.kind,started: run.started,height: run.height,originX: position.x,direction: run.direction,landedAt: now)
            }
            if run.kind != .light {
                speech = landingLines.line(role: .local,kind: run.kind,landed: true);speechUntil = now+2
            }
        }
        landing = run
        return true
    }
}

enum LandingDrawing {
    static func bounce(_ run: LandingRun,now: Double,unit: CGFloat) -> CGFloat {
        guard run.landedAt != nil else { return 0 }
        let t = run.age(at: now)
        if run.kind == .light && MeetingRole.local == .claude {
            return (t < 0.15 ? 2*unit : t < 0.3 ? unit : 0).rounded()
        }
        if run.kind == .trampoline {
            let heights: [CGFloat] = [0,3,7,10,10,7,3,0,0,2,4,5,5,4,2,0]
            return (heights[min(15,Int(t/0.0875))]*unit).rounded()
        }
        return 0
    }
    static func pixels(base: [PixelPrimitive],run: LandingRun,now: Double,anchor: CGPoint,
                       height: CGFloat,cell: CGFloat,density: CGFloat = 2) -> [PixelPrimitive] {
        let grid = PixelGrid(cell: cell,backingScale: density),u = grid.unit
        let deployed = run.deployed(at: now),landed = run.landedAt != nil,t = run.age(at: now)
        let beat = Int(max(0,now-run.started)*8)
        let kind = run.kind
        let red = "E85D75",white = "FFFFFF",gold = "F2C14E",sky = "7FB8E6",grey = "9AA0A6",dark = "3C4043"
        var back: [PixelPrimitive] = [],front: [PixelPrimitive] = []
        let sway = !landed && deployed && [.parachute,.umbrella,.balloons,.party_balloons].contains(kind) ? (beat%4 < 2 ? -u : u).rounded() : 0
        let bob = bounce(run,now: now,unit: u)
        var body = base.map { p -> PixelPrimitive in
            var r = p.rect;r.origin.x += sway;r.origin.y += bob
            if kind == .box && landed { r.origin.y -= cell }
            return .init(rect: grid.rect(r),color: p.color,interactive: p.interactive)
        }
        // Coordinates below use each pet's own cells, with Y measured up from its feet.
        func rect(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat,_ color: String,
                  behind: Bool = false,fixed: Bool = false,interactive: Bool = false) {
            let r = grid.rect(CGRect(x: anchor.x+x*cell+(fixed ? 0 : sway),y: anchor.y+y*cell+(fixed ? 0 : bob),width: w*cell,height: h*cell))
            guard r.width > 0,r.height > 0 else { return }
            let p = PixelPrimitive(rect: r,hex: color,interactive: interactive)
            if behind { back.append(p) } else { front.append(p) }
        }
        func droplet(_ x: CGFloat,_ y: CGFloat,_ color: String = "6CC4F5") { rect(x,y,0.5,1,color) }
        func balloon(_ x: CGFloat,_ y: CGFloat,_ color: String,_ rise: CGFloat = 0) {
            rect(x,y+rise,2,2.5,color);rect(x+0.5,y+2.5+rise,1,0.5,color)
            rect(x+0.5,y+1.5+rise,0.5,0.5,white);rect(x+0.5,y-0.5+rise,0.5,0.5,color)
        }
        if !deployed && !landed {
            for i in 0..<3 { rect(CGFloat(i*3-3),MeetingRole.local == .claude ? 9 : 17,0.5,2,"BFC5CC") }
            return back+body+front
        }
        if kind == .light {
            if landed && MeetingRole.local == .codex && t < 0.4 {
                for (i,x) in [CGFloat(-8),-6,6,8].enumerated() { droplet(x,1+CGFloat((Int(t*10)+i)%3)) }
            }
            return back+body+front
        }
        if MeetingRole.local == .claude {
            switch kind {
            case .parachute where !landed:
                rect(-4,17,8,1,red,behind: true);rect(-6,16,12,1,red,behind: true);rect(-7,14.5,14,1.5,red,behind: true)
                for x: CGFloat in [-5,-1,3] { rect(x,14.5,2,1.5,white,behind: true) }
                rect(-1,16,2,1,white,behind: true)
                // Four stepped cords meet the raised left/right hands.
                for (x,end): (CGFloat,CGFloat) in [(-6.5,-6),(-3,-6),(2.5,5.5),(6.5,5.5)] {
                    for row in 0..<10 { let y = 5+CGFloat(row);let xx = end+(x-end)*CGFloat(row)/9
                        rect((xx*2).rounded()/2,y,0.5,1,dark,behind: true)
                    }
                }
            case .balloons,.party_balloons:
                let colors = kind == .balloons ? [red,gold,sky] : ["F28FB1","5BD38A","B48CF2"]
                for i in 0..<3 {
                    let launch = Double(i)*0.4
                    let rise: CGFloat = landed ? CGFloat(Int(max(0,t-launch)*10))*u/cell : 0
                    if landed && t-launch > 0.7 { continue }
                    let x = CGFloat(6+i*2),y = CGFloat(17+i*2)
                    balloon(x,y,colors[i],rise)
                    if !landed || t < launch { rect(x+0.5,5,0.5,y-5,dark,behind: true) }
                }
                if kind == .party_balloons && landed {
                    for i in 0..<9 { let y = 12-Int(t*10)-(i%3)*2;if y > 0 { rect(CGFloat(i*2-8),CGFloat(y),0.5,0.5,colors[i%3]) } }
                }
            case .trampoline:
                if height <= 3*cell || landed {
                    let folded = landed && t > 1.4
                    let ground = -height/cell
                    rect(folded ? -3 : -8,ground,folded ? 6 : 16,0.5,dark,behind: true,fixed: true)
                    rect(folded ? -3 : -8,ground+0.5,folded ? 6 : 16,0.5,"5B7DB1",behind: true,fixed: true)
                    if !folded { for x: CGFloat in [-7,0,6.5] { rect(x,ground-1,0.5,1,grey,behind: true,fixed: true) } }
                }
            case .jetpack where !landed:
                rect(-8.5,2.5,2,3.5,grey,behind: true);rect(-8.5,6,2,0.5,dark,behind: true)
                rect(-8,3,0.5,2,"C6CBD0",behind: true)
                if beat%2 == 0 {
                    rect(-8.5,1,2,1.5,"F28C38",behind: true);rect(-8,-0.5,1,1.5,gold,behind: true);rect(-8,-1.5,1,1,"FFF2B3",behind: true)
                }
            case .box:
                if height <= 3*cell || landed {
                    let g = -height/cell
                    rect(-7,g,14,3,"C8935A",fixed: true);rect(-7,g+3,14,0.5,"A87542",fixed: true)
                    rect(-8,g+3,3,0.5,"C8935A",fixed: true);rect(5,g+3,3,0.5,"C8935A",fixed: true)
                    rect(-0.5,g,1,3,"E8C48A",fixed: true)
                }
            case .broom where !landed:
                rect(-10,1,18,0.5,"8B5A2B",behind: true);rect(-12,0.5,3,1.5,gold,behind: true)
                rect(-12.5,1,0.5,0.5,"D9A93A",behind: true)
                for i in 0..<3 where (beat+i)%2 == 0 { rect(CGFloat(-14-i*2),CGFloat(1+i%2),0.5,0.5,"B48CF2") }
            default: break
            }
        } else {
            switch kind {
            case .splash where landed:
                if t < 0.8 { body = [] }
                else if t < 1.08 {
                    let top = anchor.y+CGFloat(min(3,1+Int((t-0.8)/0.1)))*5*cell
                    body = body.compactMap { p in
                        var r = p.rect;let maxY = min(r.maxY,top);r.size.height = maxY-r.minY
                        let clipped = grid.rect(r)
                        return clipped.height > 0 ? .init(rect: clipped,color: p.color,interactive: p.interactive) : nil
                    }
                }
                if t < 1.08 {
                    rect(-9,0,18,1,"6CC4F5",interactive: true);rect(-8,1,16,0.5,"3A8FD6",interactive: true)
                    rect(-3,0.5,0.5,0.5,"1E2A44");rect(2,0.5,0.5,0.5,"1E2A44")
                }
                if t < 0.8 { for (i,x) in [CGFloat(-10),-7,0,7,10].enumerated() { droplet(x,CGFloat(2+(Int(t*10)+i)%5)) } }
            case .cloud where !landed:
                body = []
                rect(-6,8,12,4,"DDE6EE",interactive: true);rect(-4,12,8,1.5,"DDE6EE",interactive: true)
                rect(-7,9,1,2,"DDE6EE",interactive: true);rect(6,9,1,2,"DDE6EE",interactive: true)
                rect(-3,9.5,0.5,1,"1E2A44");rect(2.5,9.5,0.5,1,"1E2A44");rect(-0.5,9,1,0.5,"1E2A44")
                for i in 0..<5 { droplet(CGFloat(i*2-4),CGFloat(4-(beat+i)%4),"3A8FD6") }
            case .bubble:
                if !landed {
                    for i in 0..<10 {
                        rect(CGFloat(i-5),17,1,0.5,"8FC7EA");rect(CGFloat(i-5),-1,1,0.5,"8FC7EA")
                        rect(-10,CGFloat(i+3),0.5,1,"8FC7EA");rect(9.5,CGFloat(i+3),0.5,1,"8FC7EA")
                    }
                    for side: CGFloat in [-1,1] { for (x,y): (CGFloat,CGFloat) in [(6,16),(7,15),(8,14),(9,13),(6,0),(7,1),(8,2)] { rect(side*x,y,1,1,"8FC7EA") } }
                    rect(-6,13,1.5,1.5,white)
                } else {
                    for (i,p): (Int,(CGFloat,CGFloat)) in [(-9,4),(-7,16),(7,16),(9,4),(-10,9),(10,9)].enumerated() {
                        rect(p.0+(i%2 == 0 ? -1 : 1)*CGFloat(Int(t*8)),p.1,0.5,0.5,"8FC7EA")
                    }
                }
            case .umbrella where !landed:
                rect(-6.5,21,13,1,red);rect(-8,20,16,1,red);rect(-9,19,18,1,red)
                for x: CGFloat in [-6.5,-1,4.5] { rect(x,19,2,1,white) }
                rect(0,15,0.5,4,dark);rect(-0.5,22,1,1,dark)
            case .lotus where !landed:
                rect(-10.5,17.5,21,1,"5BAA5B");rect(-9,18.5,18,1,"76C176");rect(0,16,0.5,1.5,"3E8E3E")
                rect(-0.5,19.5,1,1,"F7A6B8")
            case .duck where !landed:
                let y: CGFloat = beat%2 == 0 ? 18.5 : 17.5
                rect(-6,y,3,1,"F7D33C");rect(3,y,3,1,"F7D33C");rect(-6,y-0.5,3,0.5,"E8C02C");rect(3,y-0.5,3,0.5,"E8C02C")
            case .ice:
                let melt = landed ? max(0,Int((t-0.75)*8)) : 0
                if !landed || t < 1.15 {
                    for i in 0..<18 where i%3 >= melt {
                        rect(CGFloat(i)-9,-0.5,1,0.5,"8FD3F5");rect(CGFloat(i)-9,16.5,1,0.5,"8FD3F5")
                    }
                    for i in 0..<17 where i%3 >= melt { rect(-9,CGFloat(i),0.5,1,"8FD3F5");rect(8.5,CGFloat(i),0.5,1,"8FD3F5") }
                    if melt == 0 { rect(-7.5,14.5,2,0.5,white);rect(-7.5,13,0.5,1.5,white) }
                }
                if landed && t < 0.75 { for i in 0..<3 { rect(CGFloat(-12-i*3),CGFloat(i%2),2,0.5,"BFC5CC") } }
            default: break
            }
        }
        return back+body+front
    }

}

extension PetView {
    var landingSprite: [PixelPrimitive]? { landingSprite(pixelScale: window?.backingScaleFactor ?? 2) }
    func landingSprite(pixelScale: CGFloat) -> [PixelPrimitive]? {
        guard let run = model.landing else { return nil }
        let landed = run.landedAt != nil
        #if DESK_PET
        let raised = !landed && [.parachute,.balloons,.party_balloons,.trampoline,.box].contains(run.kind)
        let base = PixelSprite.primitives(mood: .idle,act: Act(name: "落地",armL: raised ? "reach" : "",armR: raised ? "reach" : ""),outfit: model.outfit,
            elapsed: 0,anchor: anchor,mirrored: false,walking: false,pixelScale: pixelScale,cell: model.size.cell)
        #else
        // Expanded gliders replace the small head ornament for the descent.
        let outfit: Outfit = !landed && run.deployed(at: time) && [.umbrella,.lotus,.ice].contains(run.kind) ? .none : model.outfit
        let base = PixelSprite.primitives(mood: .idle,act: Act(name: "落地"),elapsed: 0,anchor: anchor,
            mirrored: false,walking: false,pixelScale: pixelScale,cell: model.size.cell,outfit: outfit)
        #endif
        // placeWindow snaps the feet before drawing. Keep floor props on the world
        // floor rather than letting the unsnapped model position make them jitter.
        let worldGrid = PixelGrid(cell: model.size.uiCell,backingScale: pixelScale)
        let height = max(0,worldGrid.snap(model.position.y)-worldGrid.snap(model.floor))
        return LandingDrawing.pixels(base: base,run: run,now: time,anchor: anchor,height: height,cell: model.size.cell,density: pixelScale)
    }
}
