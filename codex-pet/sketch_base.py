import os
# Static design sketch of the Codex pet: pixel robot with a terminal face, live CSS animations
PX = 10
C = dict(blue='#4F72F5', light='#7E98FA', deep='#3553C9', screen='#18203A', cyan='#5EE2F0', green='#5BD38A',
         ink='#2B1D1A', red='#F0605A', gold='#F2C14E', white='#FFFFFF', grey='#9AA0A6', dim='#2A3352', key='#C9D2F5')

def r(x, y, w, h, fill, cls=''):
    c = f' class="{cls}"' if cls else ''
    return f'<rect x="{x*PX}" y="{y*PX}" width="{w*PX}" height="{h*PX}" fill="{fill}"{c}/>'

def g(cls, inner): return f'<g class="{cls}">{inner}</g>'

def head():
    # A rounded cloud-ish head built from blocks
    rows = ['.....oo..oo.....', '...oooooooooo...', '..oooooooooooo..', '.oooooooooooooo.', '.oooooooooooooo.',
            '.oooooooooooooo.', '.oooooooooooooo.', '..oooooooooooo..', '...oooooooooo...']
    out = ''
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch == 'o': out += r(x + 4, y + 2, 1, 1, C['blue'])
    out += r(8, 3.3, 2.4, 0.6, C['light'])  # highlight
    return out

def screen(mood):
    base = r(6, 4.6, 12, 4.8, C['dim'] if mood == 'sleeping' else C['screen']) + r(6.4, 5, 11.2, 4, C['dim'] if mood == 'sleeping' else C['screen'])
    s = C['cyan']
    if mood == 'idle':
        face = r(8, 5.6, 0.8, 0.8, s) + r(8.8, 6.4, 0.8, 0.8, s) + r(8, 7.2, 0.8, 0.8, s) + r(11, 7.4, 2.6, 0.7, s, 'cursor')
    elif mood == 'thinking':
        face = r(9, 7, 0.9, 0.9, s, 'dot d1') + r(11.5, 7, 0.9, 0.9, s, 'dot d2') + r(14, 7, 0.9, 0.9, s, 'dot d3')
    elif mood == 'working':
        lines = [(7.2, 5.4, 6, C['green']), (8.2, 6.4, 4, s), (8.2, 7.4, 7, C['green']), (7.2, 8.4, 3, s)]
        face = g('scroll', ''.join(r(x, y, w, 0.5, c) for x, y, w, c in lines) +
                 ''.join(r(x, y + 4, w, 0.5, c) for x, y, w, c in lines))
        face = f'<clipPath id="clip"><rect x="{6.4*PX}" y="{5*PX}" width="{11.2*PX}" height="{4*PX}"/></clipPath><g clip-path="url(#clip)">{face}</g>'
    elif mood == 'done':
        gr = C['green']
        face = r(9, 7, 0.9, 0.9, gr) + r(9.9, 7.9, 0.9, 0.9, gr) + r(10.8, 7, 0.9, 0.9, gr) + r(11.7, 6.1, 0.9, 0.9, gr) + r(12.6, 5.2, 0.9, 0.9, gr)
        face = g('pop', face)
    elif mood == 'error':
        rd = C['red']
        face = (r(8, 5.8, 0.8, 0.8, rd) + r(9.6, 5.8, 0.8, 0.8, rd) + r(8.8, 6.6, 0.8, 0.8, rd) + r(8, 7.4, 0.8, 0.8, rd) + r(9.6, 7.4, 0.8, 0.8, rd) +
                r(13.6, 5.8, 0.8, 0.8, rd) + r(15.2, 5.8, 0.8, 0.8, rd) + r(14.4, 6.6, 0.8, 0.8, rd) + r(13.6, 7.4, 0.8, 0.8, rd) + r(15.2, 7.4, 0.8, 0.8, rd))
        face = g('glitch', face)
    else:  # sleeping
        face = r(8, 7.2, 2, 0.5, C['grey']) + r(14, 7.2, 2, 0.5, C['grey'])
    return base + face

def antenna(mood):
    light = {'thinking': C['gold'], 'error': C['red'], 'sleeping': C['grey'], 'done': C['green']}.get(mood, C['cyan'])
    return r(11.6, 0, 0.8, 2, C['deep']) + r(11.2, -0.8, 1.6, 1.2, light, 'blinky' if mood != 'sleeping' else '')

def body(mood, act):
    out = r(8, 11, 8, 3, C['blue']) + r(8.4, 11, 7.2, 0.5, C['deep'])
    # chest prompt
    out += r(10.2, 12, 0.6, 0.6, C['cyan']) + r(10.8, 12.5, 0.6, 0.6, C['cyan']) + r(10.2, 13, 0.6, 0.6, C['cyan']) + r(12, 13, 1.6, 0.5, C['cyan'])
    armL = {'working': 'typeL', 'done': 'up', 'error': 'flail', 'sleeping': 'droop'}.get(mood, 'wave' if mood == 'idle' else '')
    armR = {'working': 'typeR', 'done': 'up', 'error': 'flail', 'sleeping': 'droop'}.get(mood, '')
    if act in ('brace', 'test'): armL = armR = 'reach'
    out += g(armL, r(6, 11.6, 2, 1, C['blue'])) + g(armR, r(16, 11.6, 2, 1, C['blue']))
    walk = mood in ('idle', 'working') or act == 'brace'
    out += r(9.2, 14, 1.4, 1.6, C['deep'], 'legA' if walk else '') + r(13.4, 14, 1.4, 1.6, C['deep'], 'legB' if walk else '')
    out += r(8.8, 15.4, 2.2, 0.6, C['deep']) + r(13, 15.4, 2.2, 0.6, C['deep'])
    return out

def props(mood, act):
    out = ''
    if mood == 'working' and act is None:
        out += r(5, 13.4, 14, 1.2, C['key']) + ''.join(r(5.6 + i * 1.6, 13.6, 1, 0.6, C['white'], 'keyp k%d' % (i % 3)) for i in range(8))
    if act == 'test':  # progress bar above head
        out += r(5, -3.4, 14, 1.8, C['screen']) + r(5.3, -3.1, 13.4, 1.2, C['dim']) + r(5.3, -3.1, 13.4, 1.2, C['green'], 'bar')
    if act == 'brace':  # carrying a { } block
        out += r(7, -3.6, 10, 3, C['gold']) + ''.join(r(x, y, 0.6, 0.6, C['ink']) for x, y in
               [(9.2, -3.2), (8.6, -2.6), (8.2, -2.0), (8.6, -1.4), (9.2, -0.8), (14.2, -3.2), (14.8, -2.6), (15.2, -2.0), (14.8, -1.4), (14.2, -0.8)])
    if act == 'log':  # reading a long log scroll beside it
        out += r(0.4, 6, 4, 9, C['white']) + ''.join(r(0.9, 6.6 + i * 1.1, 2.6 - (i % 3) * 0.6, 0.4, C['grey']) for i in range(7))
        out += r(0.1, 5.6, 4.6, 0.6, C['key']) + r(0.1, 14.8, 4.6, 0.6, C['key'])
    if mood == 'done':
        out += ''.join(r(x, y, 0.6, 0.6, c, 'confetti c%d' % (i % 3)) for i, (x, y, c) in
                       enumerate([(2, 2, C['gold']), (5, -1, C['cyan']), (19, -1, C['green']), (22, 3, C['gold']), (1, 6, C['green'])]))
    if mood == 'error':
        out += g('smoke', r(14, -2.5, 1.4, 1.2, '#C9C9C9') + r(15.2, -3.7, 1, 1, '#DDDDDD'))
    if mood == 'sleeping':
        out += g('z', r(18, 1, 1.4, 0.4, C['ink']) + r(18.5, 1.4, 0.5, 0.5, C['ink']) + r(18, 1.9, 1.4, 0.4, C['ink']))
    if mood == 'thinking':
        out += g('bubble', r(18, 0.4, 3.4, 2.8, '#9A8A84') + r(18.1, 0.5, 3.2, 2.6, C['white']) + r(19, 1, 1.4, 0.4, C['ink']) + r(20, 1.4, 0.4, 0.6, C['ink']) + r(19.4, 2.2, 0.5, 0.4, C['ink']))
    return out

def battery(pct):
    # A battery over its shoulder showing Codex's 5-hour quota left
    fill = C['green'] if pct > 40 else C['gold'] if pct > 15 else C['red']
    return (r(19, 9.5, 3.4, 1.6, C['ink']) + r(22.4, 9.9, 0.4, 0.8, C['ink']) + r(19.2, 9.7, 3.0, 1.2, C['white']) +
            r(19.2, 9.7, 3.0 * pct / 100, 1.2, fill) +
            f'<text x="{20.7*PX}" y="{12.6*PX}" font-size="9" font-family="sans-serif" text-anchor="middle" fill="#555">{pct}%</text>')

STYLE = '''
.pet { animation: bob 1.6s steps(2) infinite; }
.m-working .pet { animation: bob .5s steps(2) infinite; } .m-done .pet { animation: jump .8s steps(4) infinite; }
.m-error .pet { animation: shake .3s steps(2) infinite; } .m-sleeping .pet { animation: bob 3s steps(2) infinite; }
.cursor { animation: blink 1s steps(1) infinite; } .blinky { animation: blink 1.4s steps(1) infinite; }
.dot { animation: blink 1.2s steps(1) infinite; } .d2 { animation-delay: .3s } .d3 { animation-delay: .6s }
.scroll { animation: scroll 1.6s steps(8) infinite; }
.glitch { animation: glitch .4s steps(2) infinite; } .pop { animation: blink 1.6s steps(1) infinite; }
.wave { animation: wave 3s steps(1) infinite; } .up { transform: translateY(-16px); } .reach { transform: translateY(-30px); }
.droop { transform: translateY(6px); } .flail { animation: flail .3s steps(1) infinite; }
.typeL { animation: tap .25s steps(1) infinite; } .typeR { animation: tap .25s steps(1) infinite .12s; }
.legA { animation: tap .5s steps(1) infinite; } .legB { animation: tap .5s steps(1) infinite .25s; }
.keyp { animation: blink .5s steps(1) infinite; } .k1 { animation-delay: .15s } .k2 { animation-delay: .3s }
.bar { transform-box: fill-box; transform-origin: 0 50%; animation: bar 3s steps(10) infinite; }
.confetti { animation: fall 1.2s steps(6) infinite; } .c1 { animation-delay: .4s } .c2 { animation-delay: .8s }
.smoke, .z { animation: rise 1.6s steps(4) infinite; }
@keyframes bob { 0%,100% { transform: none } 50% { transform: translateY(-4px) } }
@keyframes jump { 0%,100% { transform: none } 50% { transform: translateY(-20px) } }
@keyframes shake { 0%,100% { transform: translateX(-4px) } 50% { transform: translateX(4px) } }
@keyframes blink { 0%,49% { opacity: 1 } 50%,100% { opacity: 0 } }
@keyframes scroll { 0% { transform: none } 100% { transform: translateY(-40px) } }
@keyframes glitch { 0% { transform: none } 50% { transform: translateX(3px) } }
@keyframes wave { 0%,60% { transform: none } 65%,75% { transform: translateY(-20px) } 70%,80% { transform: translateY(-10px) } }
@keyframes flail { 0% { transform: translateY(-10px) } 50% { transform: translateY(5px) } }
@keyframes tap { 0% { transform: none } 50% { transform: translateY(3px) } }
@keyframes bar { 0% { transform: scaleX(.05) } 100% { transform: scaleX(1) } }
@keyframes fall { 0% { transform: none; opacity: 1 } 100% { transform: translateY(40px); opacity: 0 } }
@keyframes rise { 0% { transform: translateY(6px); opacity: 0 } 30%,70% { opacity: 1 } 100% { transform: translateY(-14px); opacity: 0 } }
'''

def pet(mood, act=None, pct=43):
    inner = antenna(mood) + head() + screen(mood) + body(mood, act)
    return (f'<svg viewBox="0 -50 240 220" width="240" height="220" shape-rendering="crispEdges" class="m-{mood}">'
            f'<rect x="40" y="162" width="160" height="2" fill="#000" opacity=".12"/><g class="pet">{inner}{props(mood, act)}</g>{battery(pct)}</svg>')

cards = [('idle', None, '闲着：屏幕上 >_ 光标闪，挥手'), ('thinking', None, '思考：屏幕跑 …，天线变黄，冒问号'),
         ('working', None, '干活：屏幕滚代码，敲键盘'), ('done', None, '完成：屏幕出绿色 ✓，举手撒彩纸'),
         ('error', None, '出错：屏幕 X X 闪红，天线红灯冒烟'), ('sleeping', None, '睡觉：屏幕变暗，冒 Z'),
         ('working', 'test', '专属动作·跑测试：头顶进度条'), ('working', 'brace', '专属动作·搬代码块：举着 { }'),
         ('thinking', 'log', '专属动作·查日志：看长长的日志')]
html = ['<!doctype html><meta charset=utf-8><title>Codex pet sketch</title><style>', STYLE,
        'body{font:14px -apple-system,sans-serif;background:#fff;color:#222;padding:16px;max-width:1100px}',
        '.grid{display:flex;flex-wrap:wrap;gap:12px}figure{margin:0;border:1px solid #eee;border-radius:8px;padding:6px}',
        'figcaption{font-size:13px;color:#555;max-width:240px}</style>',
        '<h2>Codex 桌宠草图：小码（动画为实际效果）</h2>',
        '<p>蓝色云朵头 + 终端屏幕脸，跟 Codex 的形象一致；像素风格、大小与像素小橘配套。右边的电池显示 Codex 的 5 小时额度剩余（读它的日志，不耗额度）。</p>',
        '<div class=grid>']
html += [f'<figure>{pet(m, a)}<figcaption>{t}</figcaption></figure>' for m, a, t in cards]
html.append('</div>')
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sketch.html'), 'w').write('\n'.join(html))
print('ok')