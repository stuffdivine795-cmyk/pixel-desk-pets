import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, SessionRateLimit } from 'claude-code'

import type { Mood, Outfit, Pet, Quota } from '../types'

const PANE = 'slime-pet'
const TITLE = '像素小橘'
// DeskPet is opened by bundle id, so it works wherever the app was built.
const DESK_PET_BUNDLE = 'local.deskpet.app'
const SLEEP_AFTER_MS = 3 * 60 * 1000
const DONE_FOR_MS = 8 * 1000
const ACT_EVERY_MS = 9 * 1000

const pet = atom({ plugin: 'slime-pet', key: 'pet' } as const, {
  mood: 'idle',
  detail: '',
  line: '我在这儿陪你写码',
  pokes: 0,
  outfit: 'witch',
  act: 0,
} as Pet, { shape: 'pet-3' })

const quota = atom({ plugin: 'slime-pet', key: 'quota' } as const, {} as Quota)

type Lines = Record<Mood | 'click', string[]>

const FALLBACK_LINES: Lines = {
  idle: ['我在这儿滚来滚去', '今天也要陪你写码'],
  thinking: ['让我再想一小会儿', '脑袋里在冒小泡泡'],
  working: ['小爪子开始干活啦', '这里敲敲那里补补'],
  done: ['搞定啦快夸夸我', '收工收工下班啦'],
  error: ['哎呀好像翻车了', '别怕我再试一次'],
  sleeping: ['呼噜呼噜小橘团', '有事请戳我一下'],
  click: ['哎哟别戳我肚皮', '我在呢我在呢'],
}

const LABELS: Record<Mood, string> = {
  idle: '闲逛中',
  thinking: '思考中',
  working: '干活中',
  done: '完成啦',
  error: '出错了',
  sleeping: '打瞌睡',
}

// Module variables start over on a reload; the pet itself lives in $.state
let lines: Lines = FALLBACK_LINES
let home: string | undefined
let timer: { cancel: () => void } | undefined
let acts: { cancel: () => void } | undefined

const pick = (list: string[]) => list[Math.floor(Math.random() * list.length)] ?? ''

async function loadLines($: EngineInterface) {
  home = await $.env.get('HOME')
  if (home === undefined) return
  try {
    const parsed = JSON.parse(await $.fs.read(`${home}/.claude/pet/lines.json`))
    lines = { ...FALLBACK_LINES, ...parsed }
  } catch {
    lines = FALLBACK_LINES
  }
}

// Every session running this mod reports to its own file; the desktop pet shows the busiest one
const BUSY: Record<string, number> = { working: 5, thinking: 4, error: 3, done: 2, idle: 1 }
// A busy report older than this is a session that stopped without saying so
const STALE_S = 15 * 60

type Report = { state: string; detail: string; ts: number }

async function busiest($: EngineInterface, dir: string, now: number): Promise<Report | undefined> {
  const entries = await $.fs.list(dir).catch(() => [])
  let best: Report | undefined
  for (const entry of entries) {
    if (entry.kind !== 'file' || !entry.name.endsWith('.json')) continue
    const r = await $.fs.read(`${dir}/${entry.name}`).then(t => JSON.parse(t) as Report).catch(() => undefined)
    if (r === undefined || now - r.ts > 24 * 3600) continue
    const rank = now - r.ts > STALE_S ? 1 : (BUSY[r.state] ?? 1)
    const bestRank = best === undefined ? 0 : now - best.ts > STALE_S ? 1 : (BUSY[best.state] ?? 1)
    if (rank > bestRank || (rank === bestRank && best !== undefined && r.ts > best.ts)) best = rank === 1 ? { ...r, state: 'idle' } : r
  }
  return best
}

// The desktop pet polls state.json; sleeping is its own business, so it hears idle
async function tellDesktop($: EngineInterface, mood: Mood, detail: string) {
  if (home === undefined) return
  const now = Math.floor((await $.clock.now()) / 1000)
  const dir = `${home}/.claude/pet/sessions`
  const mine: Report = { state: mood === 'sleeping' ? 'idle' : mood, detail, ts: now }
  await $.fs.write(`${dir}/${await $.session.id()}.json`, JSON.stringify(mine)).catch(() => undefined)
  const shown = (await busiest($, dir, now)) ?? mine
  const { outfit } = await read($, pet)
  const q = await read($, quota)
  const text = JSON.stringify({ state: shown.state, detail: shown.detail, outfit, quota: q, ts: now })
  await $.fs.write(`${home}/.claude/pet/state.json`, text).catch(() => undefined)
}

async function takeQuota($: EngineInterface, limits: SessionRateLimit[]) {
  const next: Quota = {}
  for (const l of limits) {
    if (l.kind === 'five_hour' || l.kind === 'seven_day') next[l.kind] = { used: l.percentUsed, resetsAt: l.resetsAt }
  }
  if (next.five_hour === undefined && next.seven_day === undefined) return
  await update($, quota, () => next)
  const p = await read($, pet)
  await tellDesktop($, p.mood, p.detail)
}

// Percent left now, counting a window whose reset has passed as full again
async function left($: EngineInterface, w: Quota['five_hour']): Promise<number | undefined> {
  if (w === undefined) return undefined
  if (w.resetsAt !== undefined && Date.parse(w.resetsAt) <= (await $.clock.now())) return 100
  return Math.max(0, Math.round(100 - w.used))
}

// Just the hour and minute, for under the battery
const hm = (iso?: string) => {
  if (iso === undefined || Date.parse(iso) <= Date.now()) return undefined
  const d = new Date(iso)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

const hhmm = (iso?: string) => {
  if (iso === undefined) return ''
  const d = new Date(iso)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getMonth() + 1}-${d.getDate()} ${pad(d.getHours())}:${pad(d.getMinutes())}`
}

async function setMood($: EngineInterface, mood: Mood, detail = '') {
  const before = await read($, pet)
  if (before.mood === mood && before.detail === detail) return
  const line = before.mood === mood ? before.line : pick(lines[mood])
  const act = before.mood === mood ? before.act : Math.floor(Math.random() * 100)
  await update($, pet, p => ({ ...p, mood, detail, line, act }))
  await tellDesktop($, mood, detail)

  timer?.cancel()
  timer = undefined
  if (mood === 'done') {
    timer = $.clock.after(DONE_FOR_MS, () => void setMood($, 'idle'))
  } else if (mood === 'idle') {
    timer = $.clock.after(SLEEP_AFTER_MS, () => void setMood($, 'sleeping'))
  }
}

// ---- the drawing: a pixel critter, in cells of PX points ----

const PX = 10
const W = 24
const H = 16
// Where the critter's top-left body cell sits in the frame
const OX = 5
const OY = 8

const C = {
  body: '#D97757',
  ink: '#2B1D1A',
  white: '#FFFFFF',
  cream: '#EDE6DA',
  gold: '#F2C14E',
  pink: '#F28FB1',
  red: '#D8453B',
  purple: '#6E4BB8',
  hat: '#2E2840',
  grey: '#9AA0A6',
  dark: '#3C4043',
  sky: '#7FB8E6',
  wood: '#8B5A2B',
  box: '#C8935A',
  green: '#6DBE6A',
}

// A rectangle in cells, relative to the critter
const r = (x: number, y: number, w: number, h: number, fill: string, cls = '') =>
  `<rect x="${(OX + x) * PX}" y="${(OY + y) * PX}" width="${w * PX}" height="${h * PX}" fill="${fill}"${cls ? ` class="${cls}"` : ''}/>`
const g = (cls: string, inner: string) => `<g class="${cls}">${inner}</g>`

const OUTFITS: Outfit[] = ['none', 'witch', 'party', 'crown', 'headphones', 'santa', 'grad', 'flower']

const OUTFIT_NAMES: Record<Outfit, string> = {
  none: '素颜',
  witch: '巫师帽',
  party: '派对帽',
  crown: '小王冠',
  headphones: '耳机',
  santa: '圣诞帽',
  grad: '学士帽',
  flower: '小花',
}

function outfit(o: Outfit): string {
  switch (o) {
    case 'witch':
      return r(1.5, -0.7, 11, 0.7, C.hat) + r(4, -1.6, 6, 0.9, C.hat) + r(4, -1.3, 6, 0.4, C.purple) +
        r(5, -2.6, 4, 1, C.hat) + r(6, -3.5, 3, 0.9, C.hat) + r(7.5, -4.3, 2, 0.8, C.hat) + r(9, -4.8, 1.2, 0.6, C.hat)
    case 'party':
      return r(5, -1, 4, 1, C.pink) + r(5.5, -2, 3, 1, C.gold) + r(6, -3, 2, 1, C.pink) +
        r(6.5, -3.8, 1, 0.8, C.gold) + r(6.3, -4.6, 1.4, 0.9, C.white)
    case 'crown':
      return r(3.5, -1, 7, 1, C.gold) + r(3.5, -2, 1, 1, C.gold) + r(6.5, -2, 1, 1, C.gold) +
        r(9.5, -2, 1, 1, C.gold) + r(6.6, -0.8, 0.8, 0.6, C.red)
    case 'headphones':
      return r(2.5, -1.3, 9, 0.6, C.dark) + r(1.9, -0.9, 0.7, 1.4, C.dark) + r(11.4, -0.9, 0.7, 1.4, C.dark) +
        r(1.2, 0.4, 1.2, 2, C.dark) + r(11.6, 0.4, 1.2, 2, C.dark) + r(1.4, 0.9, 0.5, 1, C.pink) + r(12.1, 0.9, 0.5, 1, C.pink)
    case 'santa':
      return r(3, -1.4, 8, 1, C.red) + r(4, -2.4, 6, 1, C.red) + r(5.5, -3.3, 4.5, 0.9, C.red) +
        r(8.5, -4, 3, 0.8, C.red) + r(2.6, -0.7, 8.8, 0.8, C.cream) + r(11.2, -4.5, 1.4, 1.4, C.cream)
    case 'grad':
      return r(4, -1, 6, 1, C.hat) + r(1.8, -1.8, 10.4, 0.8, C.hat) + r(6.6, -2.1, 0.8, 0.4, C.gold) +
        r(11.6, -1.4, 0.4, 2, C.gold, 'tassel') + r(11.4, 0.5, 0.8, 0.6, C.gold, 'tassel')
    case 'flower':
      return r(9.6, -1.6, 1, 1, C.pink) + r(10.6, -0.8, 1, 1, C.pink) + r(9.6, 0, 1, 0.8, C.pink) +
        r(8.6, -0.8, 1, 1, C.pink) + r(9.6, -0.8, 1, 1, C.gold) + r(8.2, 0.1, 0.8, 0.5, C.green)
    default:
      return ''
  }
}

function eyes(mood: Mood): string {
  const ink = C.ink
  switch (mood) {
    case 'done':
      // ^ ^
      return r(3.7, 1.8, 0.4, 0.4, ink) + r(4.1, 1.4, 0.4, 0.4, ink) + r(4.5, 1.8, 0.4, 0.4, ink) +
        r(8.7, 1.8, 0.4, 0.4, ink) + r(9.1, 1.4, 0.4, 0.4, ink) + r(9.5, 1.8, 0.4, 0.4, ink)
    case 'error':
      // x x
      return [3.7, 8.7].map(x =>
        r(x, 1.2, 0.4, 0.4, ink) + r(x + 0.8, 1.2, 0.4, 0.4, ink) + r(x + 0.4, 1.6, 0.4, 0.4, ink) +
        r(x, 2, 0.4, 0.4, ink) + r(x + 0.8, 2, 0.4, 0.4, ink)).join('')
    case 'sleeping':
      return r(3.8, 2, 1, 0.3, ink) + r(8.8, 2, 1, 0.3, ink)
    default:
      return g('blink', r(4.25, 1.2, 0.5, 1, ink) + r(9.25, 1.2, 0.5, 1, ink))
  }
}

// ---- props ----

const notes = (x: number, y: number) => [0, 1].map(i =>
  g(`note n${i}`, r(x + i * 2, y - i, 0.6, 0.5, C.ink) + r(x + i * 2 + 0.4, y - i - 1.2, 0.2, 1.2, C.ink) +
    r(x + i * 2 + 0.4, y - i - 1.2, 0.7, 0.3, C.ink))).join('')
const confetti = [[-3, -3, C.gold], [0, -6, C.pink], [6, -7, C.sky], [12, -6, C.gold], [16, -3, C.pink], [-1, -1, C.green]]
  .map(([x, y, c], i) => r(x as number, y as number, 0.6, 0.6, c as string, `confetti c${i % 3}`)).join('')
const EDGE = '#9A8A84'
const thought = g('bubble', g('dot d1', r(12.5, -1.7, 0.7, 0.7, EDGE) + r(12.6, -1.6, 0.5, 0.5, C.white)) +
  g('dot d2', r(13.2, -2.7, 0.9, 0.9, EDGE) + r(13.3, -2.6, 0.7, 0.7, C.white)) +
  g('dot d3', r(13.3, -5.7, 2.8, 2.6, EDGE) + r(13.4, -5.6, 2.6, 2.4, C.white) + r(14.3, -5.1, 0.8, 0.3, C.ink) + r(14.9, -4.8, 0.3, 0.5, C.ink) +
    r(14.5, -4.3, 0.4, 0.3, C.ink) + r(14.5, -3.8, 0.4, 0.3, C.ink)))
const zzz = g('z z1', r(12, -1.5, 1.2, 0.3, C.ink) + r(12.4, -1.2, 0.4, 0.4, C.ink) + r(12, -0.8, 1.2, 0.3, C.ink)) +
  g('z z2', r(13.6, -3.5, 1.6, 0.4, C.ink) + r(14.2, -3.1, 0.5, 0.5, C.ink) + r(13.6, -2.6, 1.6, 0.4, C.ink))
const sweat = r(13, 0, 0.6, 0.6, C.sky, 'sweat') + r(12.8, 0.6, 1, 0.8, C.sky, 'sweat')
const smoke = g('smoke', r(11, -3, 1.4, 1.2, '#C9C9C9') + r(12.2, -4.2, 1, 1, '#DDDDDD') + r(13, -5.2, 0.7, 0.7, '#EEEEEE'))

// Held items ride on the right arm
const HELD = {
  cup: r(12.6, 0.4, 1.4, 1.6, C.cream) + r(12.6, 0.4, 1.4, 0.3, C.wood) + r(14, 0.8, 0.4, 0.7, C.cream) +
    r(12.8, -0.6, 0.3, 0.6, '#CCCCCC', 'steam') + r(13.4, -1.2, 0.3, 0.6, '#CCCCCC', 'steam s2'),
  hammer: g('hammer', r(13, -1.6, 0.4, 3, C.wood) + r(12.2, -2.2, 2, 0.8, C.grey)),
  wand: g('hammer', r(13, -1.6, 0.3, 3, C.hat) + r(12.7, -2.2, 0.9, 0.9, C.gold)) +
    r(14.6, -3.4, 0.5, 0.5, C.gold, 'spark s1') + r(15.6, -2, 0.4, 0.4, C.pink, 'spark s2'),
  flag: r(13, -3, 0.3, 4, C.wood) + g('flutter', r(13.3, -3, 2.2, 1.4, C.red)),
} as const

// Items held up with both arms, or set in front
const FRONT = {
  laptop: r(3, 3.2, 8, 2.2, C.dark) + r(3.4, 3.5, 7.2, 1.6, C.sky, 'screen') + r(2, 5.4, 10, 0.6, C.grey),
  book: r(3.5, 2.9, 7, 2.4, '#5B7DB1') + r(4, 3.2, 3, 1.8, '#FFF8E7') + r(7, 3.2, 3, 1.8, '#FFF8E7') +
    r(7, 3.2, 3, 1.8, '#F3EAD6', 'page') + r(4.4, 3.6, 2.2, 0.2, C.grey) + r(4.4, 4.1, 2.2, 0.2, C.grey),
  box: r(3, -7, 8, 3, C.box) + r(6.6, -7, 0.8, 3, '#E8C48A'),
  trophy: r(5.5, -7, 3, 1.6, C.gold) + r(4.9, -6.8, 0.6, 0.8, C.gold) + r(8.5, -6.8, 0.6, 0.8, C.gold) +
    r(6.5, -5.4, 1, 0.8, C.gold) + r(5.8, -4.6, 2.4, 0.5, '#B8892B'),
  blanket: r(0.5, 3, 13, 3.2, '#7C9CC9') + r(0.5, 3.6, 13, 0.4, '#A9C0E0') + r(0.5, 4.8, 13, 0.4, '#A9C0E0'),
  ball: r(16, 4.6, 1.4, 1.4, C.red, 'ball') ,
  bulb: g('bulb', r(6.3, -6.8, 1.6, 1.6, C.gold) + r(6.6, -5.2, 1, 0.6, C.grey) +
    r(5, -7.4, 0.4, 0.4, C.gold) + r(8.8, -7.4, 0.4, 0.4, C.gold) + r(7, -8, 0.3, 0.5, C.gold)),
  juggle: r(4, -3, 0.9, 0.9, C.red, 'jug j1') + r(6.6, -3, 0.9, 0.9, C.sky, 'jug j2') + r(9.2, -3, 0.9, 0.9, C.green, 'jug j3'),
  stars: g('orbit', r(4, -2.4, 0.6, 0.6, C.gold) + r(7, -3, 0.6, 0.6, C.gold) + r(10, -2.4, 0.6, 0.6, C.gold)),
  bubbleNose: r(12.2, 2.2, 1, 1, '#BFE3F7', 'snot'),
} as const

type Act = {
  name: string
  // The whole critter's motion, the travel across the frame, and the arms
  body?: string
  travel?: boolean
  armL?: string
  armR?: string
  look?: 'up' | 'down' | 'around'
  walk?: boolean
  held?: keyof typeof HELD
  front?: (keyof typeof FRONT)[]
  extra?: string
  // Costume acts draw their own props: behind the critter, in front, in the right hand
  backSvg?: string
  frontSvg?: string
  heldSvg?: string
  // A class on the costume itself, so a hat can fly or bob
  hat?: string
}

const ACTS: Record<Mood, Act[]> = {
  idle: [
    { name: '散步', travel: true, walk: true, look: 'around' },
    { name: '挥手', armR: 'wave', look: 'around', body: 'bob 1.6s steps(2) infinite' },
    { name: '跳舞', body: 'dance .8s steps(2) infinite', armL: 'pumpA', armR: 'pumpB', walk: true, extra: notes(13, -1) },
    { name: '伸懒腰', body: 'stretch 3s steps(3) infinite', armL: 'reach', armR: 'reach', look: 'up' },
    { name: '喝咖啡', held: 'cup', armR: 'sip', look: 'around', body: 'bob 2.4s steps(2) infinite' },
    { name: '看书', front: ['book'], look: 'down', body: 'bob 3s steps(2) infinite' },
    { name: '抛球', front: ['juggle'], armL: 'pumpA', armR: 'pumpB', look: 'up' },
    { name: '拍球', front: ['ball'], armR: 'dribble', look: 'down', body: 'bob .6s steps(2) infinite' },
    { name: '变魔术', held: 'wand', armR: 'cast', look: 'up', body: 'bob 1.2s steps(2) infinite' },
  ],
  thinking: [
    { name: '托腮', armR: 'chin', look: 'up', body: 'bob 2.4s steps(2) infinite', extra: thought },
    { name: '踱步', travel: true, walk: true, armR: 'chin', look: 'up', extra: thought },
    { name: '灵光一闪', front: ['bulb'], look: 'up', armL: 'reach', body: 'bob 1.2s steps(2) infinite' },
  ],
  working: [
    { name: '敲键盘', front: ['laptop'], armL: 'typeL', armR: 'typeR', look: 'down', walk: false, body: 'bob .5s steps(2) infinite' },
    { name: '抡锤子', held: 'hammer', armR: 'swing', look: 'down', body: 'bob .5s steps(2) infinite' },
    { name: '搬箱子', front: ['box'], armL: 'reach', armR: 'reach', travel: true, walk: true },
  ],
  done: [
    { name: '欢呼', body: 'jump .8s steps(4) infinite', armL: 'up', armR: 'up', extra: confetti },
    { name: '举奖杯', front: ['trophy'], armL: 'reach', armR: 'reach', body: 'bob .8s steps(2) infinite', extra: confetti },
    { name: '摇旗', held: 'flag', armR: 'pumpB', body: 'dance .8s steps(2) infinite', walk: true, extra: notes(-2, -1) },
  ],
  error: [
    { name: '慌张', body: 'shake .3s steps(2) infinite', armL: 'droop', armR: 'flail', extra: sweat + smoke },
    { name: '晕倒', body: 'flat 1s steps(1) forwards', armL: 'droop', armR: 'droop', front: ['stars'] },
    { name: '团团转', travel: true, walk: true, armL: 'flail', armR: 'flail', extra: sweat },
  ],
  sleeping: [
    { name: '打呼', body: 'squish 3s steps(2) infinite', armL: 'droop', armR: 'droop', extra: zzz },
    { name: '盖被子', front: ['blanket'], body: 'squish 3s steps(2) infinite', extra: zzz },
    { name: '鼻涕泡', front: ['bubbleNose'], body: 'squish 3s steps(2) infinite', armL: 'droop', armR: 'droop' },
  ],
}

// Each costume brings acts of its own; while one is worn, every other act is one of them
type CostumeAct = Act & { moods: Mood[] }

const drop = (x: number, y: number, c: string, cls: string) => r(x, y, 0.4, 0.6, c, cls)
const heart = (x: number, y: number, cls: string) =>
  g(cls, r(x, y, 0.5, 0.5, C.pink) + r(x + 0.7, y, 0.5, 0.5, C.pink) + r(x, y + 0.4, 1.2, 0.5, C.pink) + r(x + 0.3, y + 0.8, 0.6, 0.4, C.pink))
const flake = (x: number, y: number, cls: string) =>
  g(cls, r(x + 0.3, y, 0.3, 0.9, '#9CC3E6') + r(x, y + 0.3, 0.9, 0.3, '#9CC3E6'))
const bubble = (x: number, y: number, size: number, cls: string) =>
  g(cls, r(x, y, size, size, '#8FC7EA') + r(x + 0.15, y + 0.15, size - 0.3, size - 0.3, '#EAF6FD') + r(x + 0.25, y + 0.25, 0.25, 0.25, C.white))

const COSTUME_ACTS: Record<Outfit, CostumeAct[]> = {
  witch: [
    { name: '骑扫帚', moods: ['idle', 'done'], body: 'float 1.6s steps(4) infinite',
      backSvg: r(-2, 5.2, 16, 0.5, C.wood) + r(-4, 4.6, 2.4, 1.6, C.gold) + r(-4.4, 5, 0.6, 0.8, '#D9A93A'),
      extra: r(-4, 6.2, 0.5, 0.5, C.purple, 'spark s1') + r(-5.5, 5.5, 0.4, 0.4, C.gold, 'spark s2') },
    { name: '熬魔药', moods: ['idle', 'working'], armR: 'stir', look: 'down', body: 'bob 1.2s steps(2) infinite',
      frontSvg: r(13.5, 3.4, 5, 2.8, C.hat) + r(13.2, 3.2, 5.6, 0.5, C.dark) + r(13.8, 3, 4.4, 0.5, C.green),
      heldSvg: r(13.6, 0.8, 0.3, 3, C.wood),
      extra: bubble(14.5, 1.6, 0.8, 'pot b1') + bubble(16.4, 1.2, 0.6, 'pot b2') + bubble(15.6, 0.4, 0.7, 'pot b3') },
  ],
  party: [
    { name: '吹喇叭', moods: ['idle', 'done'], body: 'bob .5s steps(2) infinite', armR: 'up',
      frontSvg: r(10.5, 2.6, 0.8, 0.5, C.gold) + g('horn', r(11.3, 2.5, 4, 0.7, C.pink) + r(15.3, 2.3, 0.6, 1.1, C.gold)),
      extra: confetti },
    { name: '彩带舞', moods: ['idle', 'done'], body: 'dance .6s steps(2) infinite', walk: true, armL: 'pumpA', armR: 'pumpB',
      heldSvg: g('flutter', r(14, 0.4, 0.5, 0.5, C.pink) + r(14.5, 0.9, 0.5, 0.5, C.gold) + r(15, 0.4, 0.5, 0.5, C.sky) + r(15.5, 0.9, 0.5, 0.5, C.green)) },
  ],
  crown: [
    { name: '坐王座', moods: ['idle', 'thinking'], armR: 'wave', look: 'around',
      backSvg: r(0.5, -3.5, 13, 9, C.red) + r(0.5, -3.5, 13, 0.6, C.gold) + r(0.5, -3.5, 0.6, 9, C.gold) + r(12.9, -3.5, 0.6, 9, C.gold) +
        r(6.4, -4.4, 1.2, 0.9, C.gold) },
    { name: '检阅', moods: ['idle'], travel: true, walk: true, armR: 'up', look: 'around',
      heldSvg: r(13, -3, 0.3, 4, C.gold) + r(12.6, -3.6, 1.1, 1.1, C.red) },
  ],
  headphones: [
    { name: '摇头听歌', moods: ['idle', 'thinking', 'working'], body: 'nod .5s steps(2) infinite', armL: 'pumpA', extra: notes(13, -1) },
    { name: '打碟', moods: ['idle', 'done'], armL: 'typeL', armR: 'typeR', look: 'down', body: 'bob .4s steps(2) infinite',
      frontSvg: r(0.5, 3.6, 13, 2.4, C.dark) + g('disc', r(1.5, 3.9, 4, 1.4, '#555B60') + r(3, 4.3, 1, 0.6, C.red)) +
        g('disc', r(8.5, 3.9, 4, 1.4, '#555B60') + r(10, 4.3, 1, 0.6, C.sky)),
      extra: notes(-3, -1) + notes(14, -2) },
  ],
  santa: [
    { name: '送礼物', moods: ['idle', 'done'], travel: true, walk: true,
      backSvg: r(-3, 0, 4.4, 4.6, '#B33A33') + r(-2.6, -0.8, 3.6, 1, '#B33A33') + r(-1.2, -1.2, 0.8, 0.5, C.gold) },
    { name: '下雪啦', moods: ['idle', 'sleeping'], look: 'up', armL: 'reach', armR: 'reach',
      extra: flake(-2, -6, 'snow s1') + flake(4, -7, 'snow s2') + flake(11, -6.5, 'snow s3') + flake(16, -5, 'snow s1') },
  ],
  grad: [
    { name: '抛帽子', moods: ['idle', 'done'], hat: 'toss', armL: 'reach', armR: 'reach', look: 'up', body: 'bob .8s steps(2) infinite' },
    { name: '念毕业词', moods: ['idle', 'thinking'], look: 'down', armR: 'chin',
      frontSvg: r(3, 2.8, 8, 2.6, C.cream) + r(2.6, 2.6, 0.6, 3, '#D8CBB4') + r(10.8, 2.6, 0.6, 3, '#D8CBB4') +
        r(4, 3.3, 5.5, 0.25, C.grey) + r(4, 3.9, 6, 0.25, C.grey) + r(4, 4.5, 4, 0.25, C.grey) + r(9.4, 4.4, 0.9, 0.9, C.red) },
  ],
  flower: [
    { name: '浇花', moods: ['idle', 'working'], look: 'down',
      heldSvg: r(13, 1.4, 2.4, 1.8, C.sky) + r(15.4, 1.2, 1.4, 0.4, C.sky) + r(13.4, 0.8, 1.6, 0.4, C.dark),
      frontSvg: r(16.2, 4.8, 2, 1.6, '#B8673C') + r(17, 3.6, 0.3, 1.2, C.green) + r(16.6, 2.8, 1.1, 1, C.pink, 'grow'),
      extra: drop(16.8, 2.2, C.sky, 'rain r1') + drop(17.4, 2.2, C.sky, 'rain r2') },
    { name: '闻花香', moods: ['idle', 'sleeping'], body: 'sway 2s steps(2) infinite',
      extra: heart(12.5, -2, 'love l1') + heart(14.5, -3.5, 'love l2') },
  ],
  none: [
    { name: '开合跳', moods: ['idle', 'done'], body: 'hop2 .8s steps(4) infinite', armL: 'pumpA', armR: 'pumpA', walk: true },
    { name: '吹泡泡', moods: ['idle', 'thinking'], look: 'up',
      heldSvg: r(13, 0.6, 0.3, 1.8, C.wood) + r(12.7, 0, 0.9, 0.9, C.pink),
      extra: bubble(14, -2, 1, 'pot b1') + bubble(15.6, -4, 1.4, 'pot b2') + bubble(13.2, -5.4, 0.8, 'pot b3') },
  ],
}

const actOf = (p: Pet): Act => {
  const list = ACTS[p.mood]
  const costume = COSTUME_ACTS[p.outfit].filter(a => a.moods.includes(p.mood))
  if (costume.length > 0 && p.act % 2 === 0) return costume[(p.act / 2) % costume.length] ?? list[0]!
  return list[p.act % list.length] ?? list[0]!
}

// A poke plays one of these on top of the act
const TRICKS = ['jump .6s steps(3) 1', 'spin .6s steps(4) 1', 'hop2 .8s steps(4) 1']

const STYLE = `
  .travel { animation: travel 9s steps(25) infinite; }
  .turn { transform-box: fill-box; transform-origin: 50% 50%; }
  .travel .turn { animation: turn 9s steps(1) infinite; }
  .pet { transform-box: fill-box; transform-origin: 50% 100%; }
  .look-around { animation: look 6s steps(1) infinite; }
  .look-up { transform: translate(2px,-3px); } .look-down { transform: translateY(4px); }
  .blink { animation: blink 3.7s steps(1) infinite; }
  .legA { animation: legA .5s steps(1) infinite; } .legB { opacity: 0; animation: legB .5s steps(1) infinite; }
  .still .legA { animation: none; } .still .legB { animation: none; }
  .wave { animation: wave 3s steps(1) infinite; }
  .chin { transform: translate(-${2 * PX}px, ${PX}px); }
  .typeL { animation: tap .25s steps(1) infinite; } .typeR { animation: tap .25s steps(1) infinite .12s; }
  .up { transform: translateY(-${1.6 * PX}px); }
  .reach { transform: translateY(-${2.5 * PX}px); }
  .droop { transform: translateY(${0.8 * PX}px); }
  .flail { animation: flail .3s steps(1) infinite; }
  .pumpA { animation: flail .8s steps(1) infinite; } .pumpB { animation: flail .8s steps(1) infinite .4s; }
  .sip { animation: sip 3s steps(1) infinite; }
  .dribble { animation: tap .6s steps(1) infinite; }
  .cast { animation: cast 1.2s steps(1) infinite; }
  .swing .hammer { transform-box: fill-box; transform-origin: 50% 100%; animation: swing .5s steps(1) infinite; }
  .cast .hammer { }
  .flutter { animation: flick .4s steps(1) infinite; }
  .screen { }
  .page { transform-box: fill-box; transform-origin: 0 50%; animation: page 2s steps(3) infinite; }
  .dot { opacity: 0; animation: pop 1.8s steps(1) infinite; }
  .d2 { animation-delay: .3s } .d3 { animation-delay: .6s }
  .confetti { animation: fall 1.2s steps(5) infinite; } .c1 { animation-delay: .4s } .c2 { animation-delay: .8s }
  .note { opacity: 0; animation: rise 1.6s steps(4) infinite; } .n1 { animation-delay: .8s }
  .sweat { animation: drip 1.2s steps(4) infinite; }
  .smoke { animation: rise 1.6s steps(4) infinite; }
  .steam { opacity: 0; animation: rise 2s steps(4) infinite; } .s2 { animation-delay: 1s }
  .spark { animation: twinkle .6s steps(1) infinite; }
  .tassel { animation: swing2 1.2s steps(2) infinite; }
  .ball { animation: ball .6s steps(3) infinite; }
  .bulb { animation: bulb 1.5s steps(1) infinite; }
  .jug { animation: jug .9s steps(4) infinite; } .j2 { animation-delay: .3s } .j3 { animation-delay: .6s }
  .orbit { animation: orbit .8s steps(4) infinite; }
  .snot { transform-box: fill-box; transform-origin: 0 0; animation: snot 3s steps(4) infinite; }
  .z { opacity: 0; animation: rise 2.4s steps(4) infinite; } .z2 { animation-delay: 1.2s }
  @keyframes travel { 0%,100% { transform: translateX(-50px) } 50% { transform: translateX(50px) } }
  @keyframes turn { 0% { transform: none } 50% { transform: scaleX(-1) } }
  @keyframes look { 0%,30% { transform: none } 32%,52% { transform: translateX(-4px) } 54%,76% { transform: translateX(4px) } 78%,100% { transform: none } }
  @keyframes blink { 0%,93% { opacity: 1 } 95%,100% { opacity: 0 } }
  @keyframes wave { 0%,30% { transform: none } 32%,48%,64% { transform: translateY(-${PX}px) } 40%,56%,72% { transform: translateY(-${2 * PX}px) } 80%,100% { transform: none } }
  @keyframes sip { 0%,55% { transform: none } 60%,85% { transform: translate(-${1.5 * PX}px,-${PX}px) } 90%,100% { transform: none } }
  @keyframes cast { 0% { transform: none } 50% { transform: translateY(-${PX}px) } }
  @keyframes bob { 0%,100% { transform: none } 50% { transform: translateY(-4px) } }
  @keyframes dance { 0%,100% { transform: translateX(-4px) } 50% { transform: translate(4px,-4px) } }
  @keyframes stretch { 0%,100% { transform: none } 50% { transform: translateY(-6px) } }
  @keyframes jump { 0%,100% { transform: none } 50% { transform: translateY(-24px) } }
  @keyframes hop2 { 0%,100% { transform: none } 25%,75% { transform: translateY(-16px) } 50% { transform: none } }
  @keyframes spin { 0%,50% { transform: none } 25%,75% { transform: scaleX(-1) } }
  @keyframes shake { 0%,100% { transform: translateX(-5px) } 50% { transform: translateX(5px) } }
  @keyframes squish { 0%,100% { transform: none } 50% { transform: translateY(2px) } }
  @keyframes flat { to { transform: rotate(90deg) } }
  @keyframes legA { 0% { opacity: 1 } 50% { opacity: 0 } }
  @keyframes legB { 0% { opacity: 0 } 50% { opacity: 1 } }
  @keyframes tap { 0% { transform: none } 50% { transform: translateY(4px) } }
  @keyframes flail { 0% { transform: translateY(-${PX}px) } 50% { transform: translateY(${0.5 * PX}px) } }
  @keyframes swing { 0% { transform: rotate(-90deg) } 50% { transform: none } }
  @keyframes swing2 { 0% { transform: none } 50% { transform: translateX(2px) } }
  @keyframes flick { 0% { opacity: 1 } 50% { opacity: 0 } }
  @keyframes page { 0% { transform: none } 50% { transform: scaleX(-1) } }
  @keyframes pop { 0%,29% { opacity: 0 } 30%,90% { opacity: 1 } 91%,100% { opacity: 0 } }
  @keyframes fall { 0% { transform: none; opacity: 1 } 90% { opacity: 1 } 91%,100% { transform: translateY(40px); opacity: 0 } }
  @keyframes drip { 0% { transform: none; opacity: 1 } 90% { opacity: 1 } 91%,100% { transform: translateY(16px); opacity: 0 } }
  @keyframes rise { 0%,9% { transform: translateY(6px); opacity: 0 } 10% { opacity: 1 } 90% { opacity: 1 } 91%,100% { transform: translateY(-14px); opacity: 0 } }
  @keyframes twinkle { 0%,49% { opacity: 0 } 50%,100% { opacity: 1 } }
  @keyframes ball { 0%,100% { transform: none } 50% { transform: translateY(-21px) } }
  @keyframes bulb { 0%,40% { opacity: 0 } 41%,100% { opacity: 1 } }
  @keyframes jug { 0%,100% { transform: none } 50% { transform: translateY(-24px) } }
  @keyframes orbit { 0% { transform: translateX(-6px) } 25% { transform: translate(0,-3px) } 50% { transform: translateX(6px) } 75% { transform: translate(0,3px) } }
  .stir { animation: stir .8s steps(2) infinite; }
  .pot { opacity: 0; animation: rise 1.4s steps(4) infinite; } .b2 { animation-delay: .45s } .b3 { animation-delay: .9s }
  .horn { transform-box: fill-box; transform-origin: 0 50%; animation: horn .6s steps(2) infinite; }
  .disc { animation: flick .25s steps(1) infinite; }
  .toss { animation: toss 1.6s steps(5) infinite; }
  .snow { animation: snow 2.4s steps(8) infinite; } .snow.s2 { animation-delay: .8s } .snow.s3 { animation-delay: 1.6s }
  .rain { animation: drip .8s steps(4) infinite; } .r2 { animation-delay: .4s }
  .grow { transform-box: fill-box; transform-origin: 50% 100%; animation: grow 2.4s steps(3) infinite; }
  .love { opacity: 0; animation: rise 2s steps(4) infinite; } .l2 { animation-delay: 1s }
  @keyframes float { 0%,100% { transform: translateY(-6px) } 50% { transform: translateY(-18px) } }
  @keyframes nod { 0%,100% { transform: none } 50% { transform: translateY(3px) } }
  @keyframes sway { 0%,100% { transform: translateX(-3px) } 50% { transform: translateX(3px) } }
  @keyframes stir { 0% { transform: translateX(10px) } 50% { transform: translate(20px, 4px) } }
  @keyframes horn { 0% { transform: scaleX(.5) } 50% { transform: none } }
  @keyframes toss { 0%,100% { transform: none } 50% { transform: translateY(-40px) } }
  @keyframes snow { 0% { transform: none; opacity: 1 } 90% { opacity: 1 } 91%,100% { transform: translate(8px, 72px); opacity: 0 } }
  @keyframes grow { 0%,100% { transform: none } 50% { transform: translateY(-5px) } }
  @keyframes snot { 0% { transform: scale(.5) } 33% { transform: none } 66% { transform: scale(1.5) } }
`

// A 3x5 pixel font for the battery's number, so nothing on the pet is smooth
const GLYPHS: Record<string, string> = {
  '0': '111101101101111', '1': '010110010010111', '2': '111001111100111', '3': '111001111001111',
  '4': '101101111001001', '5': '111100111001111', '6': '111100111101111', '7': '111001001001001',
  '8': '111101111101111', '9': '111101111001111', '%': '101001010100101', ':': '000010000010000',
}

function pixelText(text: string, x: number, y: number, dot: number, fill: string): string {
  let out = ''
  ;[...text].forEach((ch, i) => {
    const bits = GLYPHS[ch] ?? ''
    ;[...bits].forEach((bit, k) => {
      if (bit === '1') out += `<rect x="${x + (i * 4 + (k % 3)) * dot}" y="${y + Math.floor(k / 3) * dot}" width="${dot}" height="${dot}" fill="${fill}"/>`
    })
  })
  return out
}

// A pixel battery in the frame's top-right corner: the 5-hour quota left
function battery(pct: number | undefined, resets?: string): string {
  if (pct === undefined) return ''
  const fill = pct > 40 ? '#5BD38A' : pct > 15 ? C.gold : C.red
  // The number in the battery's colour, a shade darker so it reads; the time muted
  const ink = pct > 40 ? '#2E9E5B' : pct > 15 ? '#C9971C' : '#D8453B'
  const soft = pct > 40 ? '#6FB98F' : pct > 15 ? '#D9B35A' : '#E58A84'
  const at = (x: number, y: number, w: number, h: number, c: string) =>
    `<rect x="${x * PX}" y="${y * PX}" width="${w * PX}" height="${h * PX}" fill="${c}"/>`
  // Four cells of charge, lit one by one, like an old handheld's battery icon
  const cells = Math.max(pct > 0 ? 1 : 0, Math.round((pct / 100) * 4))
  let charge = ''
  for (let i = 0; i < 4; i++) charge += at(19.8 + i * 0.8, 1, 0.6, 1.2, i < cells ? fill : '#E4E4E4')
  const label = `${pct}%`
  const dot = 2
  const width = (label.length * 4 - 1) * dot
  return at(19.4, 0.6, 3.6, 2, C.ink) + at(19.6, 0.8, 3.2, 1.6, C.white) + at(23, 1.1, 0.4, 1, C.ink) + charge +
    pixelText(label, 21.2 * PX - width / 2, 3 * PX, dot, ink) +
    (resets === undefined ? '' : pixelText(resets, 21.2 * PX - ((resets.length * 4 - 1) * dot) / 2, 3 * PX + 7 * dot, dot, soft))
}

function slime(p: Pet, pct?: number, resets?: string): string {
  const act = actOf(p)
  const motions = [act.body, p.pokes > 0 ? TRICKS[p.pokes % TRICKS.length] : undefined].filter(m => m !== undefined)
  const legs = (xs: number[], cls: string) => xs.map(x => r(x, 5, 1, 1.4, C.body, cls)).join('')
  const body = p.mood === 'sleeping' ? r(2, 0.6, 10, 4.4, C.body) : r(2, 0, 10, 5, C.body)
  const look = act.look === undefined ? 'eyes' : `eyes look-${act.look}`
  const front = (act.front ?? []).map(f => FRONT[f]).join('')
  // The laptop sits in front of the body; everything else held up stays behind the arms
  const isInFront = act.front?.includes('laptop') || act.front?.includes('book') || act.front?.includes('blanket')

  const critter = `
    <g class="pet${act.walk ? '' : ' still'}"${motions.length > 0 ? ` style="animation: ${motions.join(', ')}"` : ''}>
      ${act.backSvg ?? ''}
      ${legs([3, 5, 8, 10], 'legA')}${legs([2.5, 4.5, 8.5, 10.5], 'legB')}
      ${body}
      ${g(`${look}`, eyes(p.mood))}
      ${g(act.hat ?? '', outfit(p.outfit))}
      ${isInFront ? '' : front}
      ${g(act.armL ?? '', r(0, 2, 2, 1, C.body))}
      ${g(act.armR ?? '', r(12, 2, 2, 1, C.body) + (act.held ? HELD[act.held] : '') + (act.heldSvg ?? ''))}
      ${isInFront ? front : ''}
      ${act.frontSvg ?? ''}
    </g>
    ${act.extra ?? ''}`

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W * PX} ${H * PX}" width="${W * PX}" height="${H * PX}" shape-rendering="crispEdges">
  <!-- poke ${p.pokes} act ${p.act} -->
  <style>${STYLE}</style>
  ${r(-3, 6.6, 20, 0.15, '#000000').replace('/>', ' opacity=".12"/>')}
  ${act.travel ? g('travel', g('turn', critter)) : critter}
  ${battery(pct, resets)}
</svg>`
}

// Faces for a surface that cannot draw SVG
const TEXT_FACE: Record<Mood, string> = {
  idle: '( •‿• )',
  thinking: '( ･ω･)…',
  working: '( •̀ᴗ•́ )و',
  done: '( ^▽^ )✧',
  error: '( ×﹏× )',
  sleeping: '( -ω- )zZ',
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await loadLines($)
    await $.command.register({ name: 'pet', description: '打开像素小橘面板' })
    void $.ui.open({ id: PANE, title: TITLE })
    const p = await read($, pet)
    await $.session.usage().then(u => takeQuota($, u.rateLimits)).catch(() => undefined)
    await tellDesktop($, p.mood, p.detail)
    // A new act now and then, so the critter never stands still for long
    acts?.cancel()
    acts = $.clock.every(ACT_EVERY_MS, () => void update($, pet, q => ({ ...q, act: q.act + 1 + Math.floor(Math.random() * 3) })))

    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    if (e.changed.includes('rateLimits')) await takeQuota($, e.rateLimits)

    return next(e)
  })

  on('command.run', { command: 'pet' }, async $ => {
    await $.ui.open({ id: PANE, title: TITLE })

    return { text: '像素小橘来啦。' }
  })

  on('prompt.submit', async ($, e, next) => {
    await setMood($, 'thinking')

    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    if (e.agentId === undefined) await setMood($, 'working', e.tool)
    const ran = await next(e)
    if (e.agentId === undefined) {
      if (ran.isError === true) await setMood($, 'error', `${e.tool} 出错了`)
      else await setMood($, 'thinking')
    }

    return ran
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId !== undefined) return done
    if (e.reason === 'answer') await setMood($, 'done')
    else if (e.reason === 'aborted') await setMood($, 'idle')
    else await setMood($, 'error', e.reason === 'refusal' ? '模型拒绝了' : '接口出错了')

    return done
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const p = await read($, pet)
    const q = await read($, quota)
    const five = await left($, q.five_hour)
    const week = await left($, q.seven_day)

    const poke = async () => {
      await update($, pet, q => ({ ...q, pokes: q.pokes + 1, line: pick(lines.click) }))
      if (p.mood === 'sleeping') await setMood($, 'idle')
    }
    const launch = async () => {
      const ran = await $.process.run(['open', '-b', DESK_PET_BUNDLE])
      if (ran.exitCode !== 0) $.ui.toast(`桌宠没能启动：${ran.stderr.trim() || '找不到 DeskPet.app'}`)
    }
    const dress = async () => {
      await update($, pet, q => ({ ...q, outfit: OUTFITS[(OUTFITS.indexOf(q.outfit) + 1) % OUTFITS.length] ?? 'none' }))
      await tellDesktop($, p.mood, p.detail)
    }
    const dismiss = async () => {
      await $.process.run(['pkill', '-x', 'DeskPet'])
    }

    const { Svg } = $.ui.resolve(e) as { Svg?: (props: Record<string, unknown>) => JSX.Element }
    const picture =
      // Unsupported elements can resolve to fragment constructors, not undefined.
      e.surface === 'terminal' || Svg === undefined
        ? <Text bold>{TEXT_FACE[p.mood]}</Text>
        : <Svg source={slime(p, five, hm(q.five_hour?.resetsAt))} alt={`像素小橘：${LABELS[p.mood]}`} width={W * PX} height={H * PX} isInteractive />

    return (
      <Box flexDirection="column" gap={1}>
        {picture}
        <Text bold>
          {LABELS[p.mood]}
          <Text dimColor> · {actOf(p).name}</Text>
          {p.detail !== '' && <Text dimColor> · {p.detail}</Text>}
          <Text dimColor> · {OUTFIT_NAMES[p.outfit]}</Text>
        </Text>
        <Text>“{p.line}”</Text>
        {five !== undefined && (
          <Text dimColor>
            额度：5 小时剩 {five}%（{hhmm(q.five_hour?.resetsAt)} 重置）
            {week !== undefined && ` · 每周剩 ${week}%（${hhmm(q.seven_day?.resetsAt)} 重置）`}
          </Text>
        )}
        <Box flexDirection="row" gap={1}>
          <Button key="poke" label="戳一下" onPress={poke} />
          <Button key="dress" label="换装" onPress={dress} />
          <Button key="launch" label="放到桌面" onPress={launch} />
          <Button key="dismiss" label="收回桌宠" onPress={dismiss} />
        </Box>
      </Box>
    )
  })
}
