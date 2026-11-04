import os
import importlib.util, sys
spec = importlib.util.spec_from_file_location('cs', sys.argv[1]); cs = importlib.util.module_from_spec(spec)
src = open(sys.argv[1]).read().split("cards = [")[0]
exec(src, cs.__dict__)
r, g, STYLE, battery = cs.r, cs.g, cs.STYLE, cs.battery
B = dict(body='#6CC4F5', edge='#3A8FD6', facet='#A6DDFB', shine='#FFFFFF', ink='#1E2A44', blush='#F7A6B8',
         deep='#2F6FB8', gold='#F2C14E', green='#5BD38A', red='#F0605A', grey='#9AA0A6', cloud='#DDE6EE')
OX = 4.5
SHAPE = ['.......o.......', '......ooo......', '.....ooooo.....', '....ooooooo....', '...ooooooooo...',
         '..ooooooooooo..', '..ooooooooooo..', '.ooooooooooooo.', '.ooooooooooooo.', '.ooooooooooooo.',
         '.ooooooooooooo.', '..ooooooooooo..', '...ooooooooo...', '.....ooooo.....']

def drop(mood):
    out = ''
    rows = SHAPE if mood != 'sleeping' else SHAPE[:3] + SHAPE[4:]  # a bit melted when asleep
    top = 0 if mood != 'sleeping' else 1
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch != 'o': continue
            edge = x == row.index('o') or x == row.rindex('o') or y == len(rows) - 1
            out += r(x + OX, y + top, 1, 1, B['edge'] if edge else B['body'])
    # facets and shine, like a cut gem of water
    out += r(OX + 4, top + 4, 1, 3, B['shine']) + r(OX + 5, top + 3, 1, 1, B['shine']) + r(OX + 9, top + 5, 2, 1, B['facet']) + r(OX + 10, top + 6, 1, 2, B['facet'])
    return out

def face(mood, act):
    k, y = B['ink'], 8
    cx1, cx2 = OX + 4.6, OX + 9.6
    if mood == 'done':
        e = ''.join(r(cx + dx, y + dy, 0.4, 0.4, k) for cx in (cx1 - 0.4, cx2 - 0.4) for dx, dy in [(0, 0.4), (0.4, 0), (0.8, 0.4)])
    elif mood == 'error':
        e = ''.join(r(cx + dx, y + dy, 0.4, 0.4, k) for cx in (cx1 - 0.4, cx2 - 0.4) for dx, dy in [(0, 0), (0.8, 0), (0.4, 0.4), (0, 0.8), (0.8, 0.8)])
    elif mood == 'sleeping':
        e = r(cx1 - 0.4, y + 0.6, 1.2, 0.3, k) + r(cx2 - 0.4, y + 0.6, 1.2, 0.3, k)
    else:
        lift = -0.6 if mood == 'thinking' or act == 'rain' else 0.4 if mood == 'working' else 0
        e = g('blink', r(cx1, y + lift, 0.5, 1, k) + r(cx2, y + lift, 0.5, 1, k))
    blush = r(OX + 2.6, y + 1.3, 1.2, 0.5, B['blush']) + r(OX + 11.2, y + 1.3, 1.2, 0.5, B['blush'])
    mouth = {'done': r(OX + 6.6, y + 1.2, 1.8, 0.6, k), 'error': r(OX + 6.8, y + 1.6, 1.4, 0.3, k), 'working': r(OX + 7, y + 1.3, 1, 0.5, k)}.get(mood, r(OX + 7, y + 1.4, 1, 0.3, k))
    belly = r(OX + 6.4, 11.3, 0.4, 0.4, B['deep']) + r(OX + 6.8, 11.7, 0.4, 0.4, B['deep']) + r(OX + 6.4, 12.1, 0.4, 0.4, B['deep']) + r(OX + 7.6, 12.2, 1, 0.3, B['deep'])
    return e + blush + mouth + belly

def limbs(mood, act):
    armL = {'working': 'typeL', 'done': 'up', 'error': 'flail', 'sleeping': 'droop'}.get(mood, 'wave' if mood == 'idle' else '')
    armR = {'working': 'typeR', 'done': 'up', 'error': 'flail', 'sleeping': 'droop'}.get(mood, '')
    if act in ('test',): armL = armR = 'reach'
    out = g(armL, r(OX - 0.8, 9, 1.2, 0.8, B['edge'])) + g(armR, r(OX + 14.6, 9, 1.2, 0.8, B['edge']))
    walk = mood in ('idle', 'working')
    out += r(OX + 4, 14, 2, 0.9, B['deep'], 'legA' if walk else '') + r(OX + 9, 14, 2, 0.9, B['deep'], 'legB' if walk else '')
    return out

def props(mood, act):
    out = ''
    if mood == 'working' and act is None:
        out += r(OX - 1, 12.4, 17, 1.2, '#C9D2F5') + ''.join(r(OX - 0.4 + i * 2, 12.6, 1.2, 0.6, '#FFFFFF', 'keyp k%d' % (i % 3)) for i in range(8))
    if act == 'test':
        out += r(OX - 1, -3.4, 17, 1.8, '#18203A') + r(OX - 0.7, -3.1, 16.4, 1.2, '#2A3352') + r(OX - 0.7, -3.1, 16.4, 1.2, B['green'], 'bar')
    if act == 'rain':  # a tiny cloud raining on it, it loves that
        out += r(OX + 3, -4, 9, 2, B['cloud']) + r(OX + 4.5, -5, 5, 1.2, B['cloud'])
        out += ''.join(r(OX + x, -1.6, 0.3, 0.7, B['edge'], 'rain r%d' % (i % 2)) for i, x in enumerate([4, 6, 8, 10]))
    if act == 'splash':  # little droplets jumping off
        out += ''.join(r(OX + x, y, 0.6, 0.8, B['body'], 'confetti c%d' % (i % 3)) for i, (x, y) in enumerate([(-2, 4), (0, 1), (14, 1), (16, 4), (7, -2)]))
    if mood == 'done' and act is None:
        out += ''.join(r(OX + x, y, 0.6, 0.6, c, 'confetti c%d' % (i % 3)) for i, (x, y, c) in
                       enumerate([(-2, 2, B['gold']), (1, -1, B['green']), (13, -1, B['gold']), (16, 3, B['green'])]))
    if mood == 'error':
        out += g('smoke', r(OX + 12, -1.5, 1.4, 1.2, '#C9C9C9') + r(OX + 13.2, -2.7, 1, 1, '#DDDDDD'))
    if mood == 'sleeping':
        out += g('z', r(OX + 14, 1, 1.4, 0.4, B['ink']) + r(OX + 14.5, 1.4, 0.5, 0.5, B['ink']) + r(OX + 14, 1.9, 1.4, 0.4, B['ink']))
    if mood == 'thinking':
        out += g('bubble', r(OX + 13, -1.6, 3.4, 2.8, '#9A8A84') + r(OX + 13.1, -1.5, 3.2, 2.6, '#FFFFFF') + r(OX + 14, -1, 1.4, 0.4, B['ink']) + r(OX + 15, -0.6, 0.4, 0.6, B['ink']) + r(OX + 14.4, 0.2, 0.5, 0.4, B['ink']))
    return out

def pet(mood, act=None, pct=43):
    inner = drop(mood) + face(mood, act) + limbs(mood, act)
    return (f'<svg viewBox="0 -60 260 220" width="260" height="220" shape-rendering="crispEdges" class="m-{mood}">'
            f'<rect x="50" y="152" width="140" height="2" fill="#000" opacity=".12"/><g class="pet">{inner}{props(mood, act)}</g><g transform="translate(30,0)">{battery(pct)}</g></svg>')

EXTRA = '.rain { animation: drip .6s steps(3) infinite; } .r1 { animation-delay: .3s } @keyframes drip { 0% { transform: none; opacity: 1 } 100% { transform: translateY(14px); opacity: 0 } } .blink { animation: blink2 3.6s steps(1) infinite; } @keyframes blink2 { 0%,93% { opacity: 1 } 95%,100% { opacity: 0 } }'
cards = [('idle', None, '闲着：眨眼、轻轻晃、挥手'), ('thinking', None, '思考：眼睛往上看，冒问号'),
         ('working', None, '干活：敲键盘，小脚踏步'), ('done', None, '完成：^ ^ 眯眼笑，跳起来撒彩纸'),
         ('error', None, '出错：X X 眼，晃动冒烟'), ('sleeping', None, '睡觉：化开一点、变扁，冒 Z'),
         ('working', 'test', '专属动作·跑测试：头顶进度条'), ('idle', 'rain', '专属动作·淋小雨：头顶小云下雨，它很开心'),
         ('done', 'splash', '专属动作·溅水花：跳起来甩出小水珠')]
html = ['<!doctype html><meta charset=utf-8><title>Codex pet sketch</title><style>', STYLE, EXTRA,
        'body{font:14px -apple-system,sans-serif;background:#fff;color:#222;padding:16px;max-width:1100px}',
        '.grid{display:flex;flex-wrap:wrap;gap:12px}figure{margin:0;border:1px solid #eee;border-radius:8px;padding:6px}',
        'figcaption{font-size:13px;color:#555;max-width:240px}</style>',
        '<h2>Codex 桌宠草图 v2：小水滴（动画为实际效果）</h2>',
        '<p>一颗像宝石切面的蓝色水滴，细缝小眼睛 + 腮红，肚子上一个小小的 <code>&gt;_</code> 表示它是 Codex 的；像素风格与像素小橘配套。右边电池 = Codex 5 小时额度剩余。</p>',
        '<div class=grid>']
html += [f'<figure>{pet(m, a)}<figcaption>{t}</figcaption></figure>' for m, a, t in cards]
html.append('</div>')
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sketch.html'), 'w').write('\n'.join(html))
print('ok')