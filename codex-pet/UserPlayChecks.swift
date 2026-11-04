// Task 13: cursor eyes, feeding limit, throw speed/flight, catch decision, clock timing, prop pixels.
let userCheckStart = checks
let userRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/checks/user-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: userRoot,withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: userRoot) }
let userSuite = "user-checks-\(UUID().uuidString)"
let userDefaults = UserDefaults(suiteName: userSuite)!
defer { userDefaults.removePersistentDomain(forName: userSuite) }
let up = UserPlay(directory: userRoot,defaults: userDefaults)

// Eyes: one whole step toward the cursor, nothing out of range or while blocked.
let eyeCenter = CGPoint(x: 500,y: 100)
check(UserPlay.eyeOffset(cursor: CGPoint(x: 600,y: 100),center: eyeCenter,range: 150) == CGPoint(x: 0.5,y: 0),"eyes step right")
check(UserPlay.eyeOffset(cursor: CGPoint(x: 400,y: 100),center: eyeCenter,range: 150) == CGPoint(x: -0.5,y: 0),"eyes step left")
check(UserPlay.eyeOffset(cursor: CGPoint(x: 505,y: 200),center: eyeCenter,range: 150) == CGPoint(x: 0,y: -0.5),"eyes look up at a cursor above")
check(UserPlay.eyeOffset(cursor: CGPoint(x: 700,y: 100),center: eyeCenter,range: 150) == .zero,"cursor out of range")
let eyeBody = CGRect(x: 450,y: 60,width: 100,height: 80)
up.updateCursor(CGPoint(x: 600,y: 100),body: eyeBody,mirrored: true,range: 150,blocked: false,now: 10)
check(up.eyeShift == CGPoint(x: -0.5,y: 0),"mirrored sprite flips the eye step")
up.updateCursor(CGPoint(x: 600,y: 100),body: eyeBody,mirrored: false,range: 150,blocked: true,now: 10)
check(up.eyeShift == .zero && !up.hold,"no eye shift while asleep, dragged or busy")
up.updateCursor(CGPoint(x: 500,y: 100),body: eyeBody,mirrored: false,range: 150,blocked: false,now: 20)
check(!up.hold,"resting cursor does not hold at once")
up.updateCursor(CGPoint(x: 500,y: 100),body: eyeBody,mirrored: false,range: 150,blocked: false,now: 22)
check(up.hold && up.eyeShift == CGPoint(x: 0,y: -0.5) && up.blocksWalk,"cursor resting 2 s on the pet: looks up and stops walking")
up.updateCursor(CGPoint(x: 900,y: 100),body: eyeBody,mirrored: false,range: 150,blocked: false,now: 23)
check(!up.hold,"cursor leaving releases the hold")

// Feeding: three a minute, then a head shake.
check(up.feed(now: 100) && up.feed(now: 101) && up.feed(now: 102),"three feeds allowed")
check(!up.feed(now: 103) && up.active(103) == .refuse,"fourth feed in a minute refused with a shake")
check(up.feed(now: 161),"feeding allowed again after a minute")
check(up.active(161) == .feed && up.active(161+up.duration(.feed)) == nil,"feed animation ends")
check(up.mirror(now: 161+1.3) != up.mirror(now: 161+1.5),"feed spin mirrors back and forth")

// Throw speed from the last 0.1 s of the drag.
up.resetTrack()
for (t,x) in [(0.0,0.0),(0.05,60.0),(0.1,120.0)] { up.track(CGPoint(x: x,y: 300),now: 50+t) }
check(abs(up.releaseVelocity(now: 50.1)-1200) < 1 && up.releaseVelocity(now: 50.1) >= UserPlay.throwThreshold,"fast release is a throw")
up.resetTrack()
for (t,x) in [(0.0,0.0),(0.05,15.0),(0.1,30.0)] { up.track(CGPoint(x: x,y: 300),now: 60+t) }
check(up.releaseVelocity(now: 60.1) < UserPlay.throwThreshold,"slow release is a normal drop")
up.resetTrack();up.track(CGPoint(x: 0,y: 0),now: 70)
check(up.releaseVelocity(now: 70) == 0,"a single sample has no speed")

// Flight stays on screen and comes to rest.
var flightX: CGFloat = 1200
up.beginThrow(-5000)
check(up.throwVX == -2400,"throw speed is capped")
var flightTime = 0.0
while up.throwVX != 0 && flightTime < 10 {
    up.stepThrow(x: &flightX,minX: 104,maxX: 1336,grounded: flightTime > 0.4,dt: 1.0/60)
    check(flightX >= 104 && flightX <= 1336,"thrown pet stays inside the screen")
    flightTime += 1.0/60
}
check(up.throwVX == 0 && flightTime < 10,"thrown pet comes to rest")
up.beginThrow(2400);flightX = 1300
for _ in 0..<30 { up.stepThrow(x: &flightX,minX: 104,maxX: 1336,grounded: false,dt: 1.0/60) }
check(flightX <= 1336 && up.throwVX <= 0,"bounces off the screen edge")

// Catch or bump, decided once when the flight reaches the other pet.
let peerFresh = MeetingPosition(x: 800,y: 36,screen: "0,0,1440,900",facing: "left",mood: "idle",detail: "",busy: false,ts: 1000)
up.beginThrow(1500)
check(up.resolveCatch(x: 600,peer: peerFresh,reach: 120,sameScreen: true,epoch: 1000,now: 200,roll: 0) == nil,"no decision before reaching the peer")
let caught = up.resolveCatch(x: 690,peer: peerFresh,reach: 120,sameScreen: true,epoch: 1000,now: 200,roll: 0.5)
check(caught?.caught == true && caught?.x == 680 && up.throwVX == 0 && up.active(200) == .caught,"70 % roll: caught, put down beside the peer")
check(up.resolveCatch(x: 690,peer: peerFresh,reach: 120,sameScreen: true,epoch: 1000,now: 200,roll: 0.5) == nil,"decided only once per throw")
let catchFile = try JSONSerialization.jsonObject(with: Data(contentsOf: userRoot.appendingPathComponent("catch.json"))) as! [String: Any]
check(catchFile["caught"] as? Bool == true && catchFile["thrower"] as? String == MeetingRole.local.rawValue && !((catchFile["lines"] as? [Any]) ?? []).isEmpty,"catch.json tells the peer what happened")
up.beginThrow(1500)
let bumped = up.resolveCatch(x: 690,peer: peerFresh,reach: 120,sameScreen: true,epoch: 1000,now: 300,roll: 0.9)
check(bumped?.caught == false && up.throwVX < 0,"30 % roll: bumped and bounces back")
up.beginThrow(-1500)
check(up.resolveCatch(x: 690,peer: peerFresh,reach: 120,sameScreen: true,epoch: 1000,now: 300,roll: 0) == nil,"flying away never catches")
var busyPeer = peerFresh;busyPeer.busy = true
up.beginThrow(1500)
check(up.resolveCatch(x: 690,peer: busyPeer,reach: 120,sameScreen: true,epoch: 1000,now: 300,roll: 0) == nil,"busy peer doesn't catch")
check(up.resolveCatch(x: 690,peer: peerFresh,reach: 120,sameScreen: false,epoch: 1000,now: 300,roll: 0) == nil,"other screen doesn't catch")
check(up.resolveCatch(x: 690,peer: peerFresh,reach: 120,sameScreen: true,epoch: 1010,now: 300,roll: 0) == nil,"stale peer doesn't catch")
up.stopThrow()

// Clock: morning once a day; late every 30 minutes while active, 小水滴 a minute after 小橘.
func userDate(_ day: Int,_ hour: Int,_ minute: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026,month: 11,day: day,hour: hour,minute: minute))!
}
check(up.clockEvent(date: userDate(5,8,0),inputIdle: 10,now: 1000) == .morning,"first activity in the morning")
check(up.clockEvent(date: userDate(5,9,30),inputIdle: 10,now: 1100) == nil,"morning once per day")
check(up.clockEvent(date: userDate(6,7,0),inputIdle: 300,now: 1200) == nil,"no morning greeting while away")
check(up.clockEvent(date: userDate(6,7,5),inputIdle: 10,now: 1300) == .morning,"next day greets again")
check(up.clockEvent(date: userDate(6,12,0),inputIdle: 10,now: 1400) == nil,"nothing at noon")
let lateStart = userDate(7,0,10)
let stagger: Double = MeetingRole.local == .codex ? 60 : 0
if stagger > 0 { check(up.clockEvent(date: lateStart,inputIdle: 10,now: 2000) == nil,"小水滴 waits a minute after 小橘") }
check(up.clockEvent(date: lateStart.addingTimeInterval(stagger+1),inputIdle: 10,now: 2000+stagger+1) == .late,"late-night reminder")
check(up.clockEvent(date: lateStart.addingTimeInterval(stagger+300),inputIdle: 10,now: 2300+stagger) == nil,"only once per 30-minute slot")
check(up.clockEvent(date: userDate(7,0,31).addingTimeInterval(stagger),inputIdle: 10,now: 3300) == .late,"next half hour reminds again")
check(up.clockEvent(date: userDate(7,1,5),inputIdle: 600,now: 5000) == nil,"no reminder while the user is away")
check(up.clockEvent(date: userDate(7,5,10),inputIdle: 10,now: 9000) == nil,"no reminder after 05:00")

// Props: opaque, axis-aligned, whole device pixels, at every size and both backing scales.
for cell in [CGFloat(6),8,10] { for scale in [CGFloat(1),2] {
    let grid = PixelGrid(cell: cell,backingScale: scale)
    let body = CGRect(x: 120,y: 40,width: 14*cell,height: 9*cell)
    for (anim,times) in [(UserAnim.feed,[0.1,0.5,1.0,1.5,2.2]),(.bumped,[0.1,0.3]),(.caught,[0.2]),(.morning,[0.1,0.3]),(.late,[1.0])] {
        for t in times {
            up.start(anim,now: 500);up.beginThrow(anim == .bumped ? 1200 : 0)
            let fills = up.overlay(now: 500+t,body: body,grid: grid)
            check(!fills.isEmpty || anim == .caught || (anim == .feed && t >= 0.9 && t < 1.2),"\(anim) draws props at \(t)")
            for f in fills {
                let r = f.rect
                check(r.width > 0 && r.height > 0 && [r.minX,r.minY,r.width,r.height].allSatisfy { abs(($0*scale).rounded()-$0*scale) < 0.001 },
                      "\(anim) prop on whole pixels (cell \(cell), \(scale)x)")
            }
            up.stopThrow()
        }
    }
} }
print("PASS: \(checks-userCheckStart) Task 13 user-interaction assertions")
