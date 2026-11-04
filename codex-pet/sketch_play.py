# Interaction sketch: 12 new things the two pets (or the user) can do, one animated panel each
import json, os, re, sys
here = os.path.dirname(os.path.abspath(__file__))
critters = dict(json.loads(l[5:]) for l in open(sys.argv[1]) if l.startswith('SVG>>'))
lines = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else {}

src = open(os.path.join(here, 'sketch_drop.py')).read().split("EXTRA = ")[0]
sys.argv = ['x', os.path.join(here, 'sketch_base.py')]; ns = {}; exec(src, ns)
r, OX, STYLE, B = ns['r'], ns['OX'], ns['STYLE'], ns['B']
CRITTER_STYLE = re.search(r'<style>(.*?)</style>', next(iter(critters.values())), re.S).group(1)

INK, RED, WHITE, GOLD, SKY, GREY, DARK, GREEN, BROWN = '#2B1D1A', '#E85D75', '#FFFFFF', '#F2C14E', '#7FB8E6', '#9AA0A6', '#3C4043', '#5BD38A', '#B07A45'

def body(svg):
    svg = re.sub(r'<rect[^>]*opacity="\.12"/>', '', svg)
    return re.sub(r'<style>.*?</style>', '', re.sub(r'^<svg[^>]*>|</svg>\s*$', '', svg.strip()), flags=re.S)

def cr(x, y, w, h, c, cls=''):
    # a rect in the critter's cells (its frame puts cell 0,0 at 50,80)
    k = f' class="{cls}"' if cls else ''
    return f'<rect x="{(5+x)*10}" y="{(8+y)*10}" width="{w*10}" height="{h*10}" fill="{c}"{k}/>'

def critter(key='idle', dx=0, dy=0, cls=''):
    return f'<g transform="translate({dx},{dy})"><g class="{cls}">{body(critters[key])}</g></g>'

DX, DY = 270, -7  # where the drop stands, to the right of the critter
def drop(mood='idle', extra='', dx=DX, dy=DY, cls=''):
    return f'<g transform="translate({dx},{dy})"><g class="{cls}">{ns["drop"](mood)}{ns["face"](mood, None)}{ns["limbs"](mood, None)}{extra}</g></g>'

FONT = {'G': ['111', '100', '101', '101', '111'], 'O': ['111', '101', '101', '101', '111'], '!': ['010', '010', '010', '000', '010'],
        'Z': ['111', '001', '010', '100', '111'], '?': ['111', '001', '011', '000', '010'], '+': ['000', '010', '111', '010', '000'],
        '0': ['111', '101', '101', '101', '111'], '1': ['010', '110', '010', '010', '111'], '3': ['111', '001', '111', '001', '111'], ':': ['0', '1', '0', '1', '0']}
def text(s, x, y, px, c, rel=cr):
    out, cx = '', x
    for ch in s:
        rows = FONT[ch]
        for j, row in enumerate(rows):
            for i, b in enumerate(row):
                if b == '1': out += rel(cx + i * px, y + j * px, px, px, c)
        cx += (len(rows[0]) + 1) * px
    return out

def star(x, y, c, rel=cr, cls='flick'):
    return rel(x + 0.5, y, 0.5, 1.5, c, cls) + rel(x, y + 0.5, 1.5, 0.5, c, cls)
def burst(x, y, c, rel=cr):
    pts = [(0, -2), (0, 2), (-2, 0), (2, 0), (-1.5, -1.5), (1.5, -1.5), (-1.5, 1.5), (1.5, 1.5)]
    return rel(x, y, 0.6, 0.6, WHITE, 'flick') + ''.join(rel(x + a, y + b, 0.6, 0.6, c, 'flick') for a, b in pts)
cookie = lambda x, y, rel=cr: rel(x, y, 2.4, 2.4, BROWN) + rel(x + 0.5, y + 0.5, 0.5, 0.5, INK) + rel(x + 1.4, y + 1.3, 0.5, 0.5, INK)
def batt(x, y, segs, c, rel=cr):
    return (rel(x, y, 4.4, 2.2, DARK) + rel(x + 4.4, y + 0.6, 0.5, 1, DARK) + rel(x + 0.3, y + 0.3, 3.8, 1.6, '#EEF1F4') +
            ''.join(rel(x + 0.5 + i * 0.9, y + 0.5, 0.7, 1.2, c) for i in range(segs)))
ball = lambda: cr(0, 0, 2, 2, WHITE) + cr(0.6, 0.6, 0.8, 0.8, INK) + cr(0, 0, 2, 0.3, DARK) + cr(0, 1.7, 2, 0.3, DARK)
fish = cr(13, 1.6, 2.4, 1.2, '#9DB4C8') + cr(15.4, 1.2, 0.8, 2, '#9DB4C8') + cr(13.4, 1.8, 0.4, 0.4, INK)
heart = lambda x, y, rel=cr, cls='float': (rel(x, y, 0.6, 0.6, RED, cls) + rel(x + 1, y, 0.6, 0.6, RED, cls) + rel(x, y + 0.6, 1.6, 0.6, RED, cls) + rel(x + 0.5, y + 1.2, 0.6, 0.5, RED, cls))
arrow = ''.join(f'<rect x="{x}" y="{y}" width="{w}" height="5" fill="{c}"/>' for x, y, w, c in
                [(0, 0, 5, INK), (0, 5, 10, INK), (0, 10, 15, INK), (0, 15, 20, INK), (0, 20, 10, INK), (5, 25, 5, INK)]) + \
        ''.join(f'<rect x="{x}" y="{y}" width="{w}" height="5" fill="#fff"/>' for x, y, w in [(5, 10, 5), (5, 15, 10)])
zz = ''.join(f'<g class="float">{text("Z", x, y, s, "#7B8794")}</g>' for x, y, s in [(14.6, -4, 0.4), (16.6, -6.4, 0.5)])

def panel(content, sky=''):
    return (f'<svg viewBox="-40 -110 560 290" width="380" height="197" shape-rendering="crispEdges">{sky}'
            f'<rect x="-40" y="144" width="560" height="3" fill="#D5D9DE"/>{content}</svg>')

def say(key):
    v = lines.get(key)
    if not v: return ''
    if isinstance(v, list):
        return '<p class=say>' + '　'.join(f'{"小橘" if l["who"] == "claude" else "小水滴"}：「{l["text"]}」' for l in v[0]) + '</p>'
    if 'claude' in v:
        return f'<p class=say>小橘：「{v["claude"][0]}」　小水滴：「{v["codex"][0]}」</p>'
    return f'<p class=say>早上 小橘：「{v["morning"]["claude"][0]}」　半夜 小水滴：「{v["late"]["codex"][0]}」</p>'

def card(no, title, when, what, svg, key=None):
    return f'<section><h4>{no} {title}</h4><p class=when>触发：{when}</p>{svg}<p class=note>{what}</p>{say(key) if key else ""}</section>'

R = lambda x, y, w, h, c, cls='': r(OX + x, y, w, h, c, cls)  # drop-cell rect, used inside drop(extra=...)

cards = [
    # —— 跟工作状态联动 ——
    card('①', '完成庆祝', '我或 Codex 有一轮任务做完', '另一只跑过来，两只举手击掌，头顶冒一圈像素星星，然后各回各位。',
         panel(critter('happy', 60) + drop('done', dx=DX - 60) + star(6, -6, GOLD) + star(13, -8, '#F28FB1') + star(20, -5, GOLD)), 'celebrate'),
    card('②', '报错安慰', '一方报错', '报错的那只垂头丧气；另一只走过去拍拍它的头，再递一块小饼干，对方吃完恢复正常。',
         panel(critter('idle', 60) + cr(10, -6, 7, 2, '#8A939E') + cr(11, -7, 4, 1, '#8A939E') + ''.join(cr(x, -3.6, 0.3, 0.8, '#3A8FD6', 'drip2') for x in (11, 13, 15)) + drop('idle', R(-3, 7, 2.4, 2.4, BROWN) + R(-2.5, 7.5, 0.5, 0.5, INK) + R(-1.6, 8.3, 0.5, 0.5, INK), dx=DX - 60)), 'comfort'),
    card('③', '陪着干活', '一方干活超过 1 分钟、另一只闲着', '闲着的那只走到旁边坐下，举起「GO!」小牌子左右摇，偶尔冒个爱心。',
         panel(critter('idle') + f'<g class="sway2">{cr(12, -9, 0.4, 7, BROWN)}{cr(9.6, -12, 5.2, 3.6, WHITE)}{cr(9.6, -12, 5.2, 0.3, DARK)}{text("GO!", 10, -11.4, 0.45, RED)}</g>'
               + drop('working', ns['props']('working', None)) + heart(4, -4)), 'cheer'),
    card('④', '递电池 / 重置放烟花', '一方 5 小时额度低于 20%；额度重置时', '额度低的那只头顶亮红色空电池，另一只递来一块满格电池；额度一重置，两只一起举手放烟花。',
         panel(critter('idle') + batt(5, -5, 1, '#D8453B') + drop('idle', f'<g class="float">{batt(-6, 4, 4, "#2E9E5B", R)}</g>', dx=DX - 40))
         + panel(critter('up') + drop('done') + burst(4, -9, '#F28FB1') + burst(17, -11, GOLD) + burst(29, -8, '#5BD38A')), 'give_battery'),
    # —— 两只自己玩 ——
    card('⑤', '踢小球', '两只都闲着、离得近（随机）', '一个黑白像素小球在两只之间来回滚，谁没接住就追着球跑一段。',
         panel(critter('idle') + f'<g class="kick">{ball()}</g>' + drop('idle')), 'soccer'),
    card('⑥', '石头剪刀布', '两只都闲着（随机）', '两只头顶同时亮出手势图标，数三下揭晓；输的那只吐舌头做鬼脸，赢的跳一下。',
         panel(critter('happy') + cr(4, -9, 3.6, 3, '#F2A65A') + cr(4, -9, 3.6, 0.6, '#D9822B') + cr(3.6, -8.4, 0.4, 1.8, '#D9822B')
               + drop('idle', R(5.8, -6, 0.9, 3.6, SKY) + R(8.4, -6, 0.9, 3.6, SKY) + R(6.4, -2.6, 2.4, 1.4, '#3A8FD6') + R(7, 9.6, 1, 1.2, RED))), 'rps'),
    card('⑦', '捉迷藏', '两只都闲着（随机）', '一只跑到屏幕边，只露出半个身子；另一只头顶冒「?」到处找，找到后两只一起跳一下。',
         panel(critter('idle', -30) + text('?', 6, -7, 0.6, '#7B8794').replace('<rect', '<rect class="flick"', 1)
               + f'<g class="peek">{drop("idle", dx=DX + 90)}</g>' + '<rect x="440" y="-110" width="80" height="260" fill="#C8CED6"/>'
               + '<rect x="440" y="-110" width="4" height="260" fill="#9AA0A6"/>'), 'hide_seek'),
    card('⑧', '一起打盹', '10 分钟没人理、两只都闲着', '两只走到一起肩并肩，小水滴化成软软的一团，小橘闭眼，头顶飘 Zzz；你点任意一只就醒。',
         panel(critter('idle', 70) + zz + drop('sleeping', dx=DX - 70)
               + f'<g class="float">{text("Z", 22, -7, 0.4, "#7B8794")}</g>'), 'nap'),
    # —— 跟你互动 ——
    card('⑨', '眼睛跟着鼠标', '鼠标靠近（150pt 内）', '眼睛朝鼠标方向挪一格；鼠标停在身上不动 2 秒，它会抬头看你。',
         panel(critter('idle') + drop('idle', dx=DX - 10) + f'<g transform="translate(470,-60)">{arrow}</g>'), None),
    card('⑩', '双击喂零食', '双击宠物', '小橘接住一条小鱼干啃两口，小水滴张嘴接一滴水，吃完冒爱心、开心转一圈。同一只 1 分钟内最多吃 3 次。',
         panel(critter('happy') + fish + heart(2, -6)
               + drop('done', R(7, -4, 1, 1.4, SKY, 'drip2') + R(7.2, -4.4, 0.6, 0.4, SKY, 'drip2')) + heart(27, -6)), 'eat'),
    card('⑪', '扔过去接住', '把一只拖起来朝另一只方向甩出去', '被扔的那只横着飞过去；对方举手接住，两只一起转一圈；没接准就撞得对方晃两下、冒星星。',
         panel(f'<g class="fly">{critter("up", 0, -40)}{cr(-3, -3, 2.5, 0.3, "#BFC5CC")}{cr(-4, -1.5, 3, 0.3, "#BFC5CC")}</g>' + drop('done')), 'catch'),
    card('⑫', '看时间说话', '早上 7～9 点第一次见到你；过了半夜 12 点每 30 分钟', '早上伸个大懒腰，旁边升起像素太阳；半夜举「0:30」小牌子提醒你去睡觉，旁边挂月亮。',
         panel(critter('up') + cr(-6, -9, 3, 3, GOLD) + ''.join(cr(-4.8 + a, -7.8 + b, 0.6, 0.6, GOLD, 'flick') for a, b in [(0, -2.6), (0, 2.6), (-2.6, 0), (2.6, 0)])
               + drop('idle'), '')
         + panel(critter('idle') + drop('idle', R(3, -6, 0.4, 6, BROWN) + R(0, -9.6, 9, 3.8, WHITE) + text('0:30', 0.6, -8.8, 0.45, '#2F6FB8', R))
                 + cr(-6, -10, 3, 3, '#F5E7A1') + cr(-5, -10, 2, 2, '#2A3352'),
                 '<rect x="-40" y="-110" width="560" height="254" fill="#2A3352"/>'), 'clock'),
]

EXTRA = '''
.float { animation: float 1.6s steps(4) infinite; } @keyframes float { 0%,100% { transform: translateY(0) } 50% { transform: translateY(-8px) } }
.flick { animation: flick2 .4s steps(1) infinite; } @keyframes flick2 { 50% { opacity: 0 } }
.sway2 { animation: sway2 1.2s steps(2) infinite; } @keyframes sway2 { 0%,100% { transform: translateX(-4px) } 50% { transform: translateX(4px) } }
.drip2 { animation: drip2 .8s steps(4) infinite; } @keyframes drip2 { 0% { transform: none } 100% { transform: translateY(40px) } }
.kick { animation: kick 2.4s steps(12) infinite; } @keyframes kick { 0%,100% { transform: translate(150px,44px) } 50% { transform: translate(290px,44px) } }
.peek { animation: peek 2s steps(2) infinite; } @keyframes peek { 0%,40% { transform: translateX(0) } 50%,90% { transform: translateX(60px) } }
.fly { animation: fly 1.6s steps(8) infinite; } @keyframes fly { 0% { transform: translateX(-40px) } 100% { transform: translateX(110px) } }
'''

html = f'''<!doctype html><meta charset=utf-8><title>新互动草图</title><style>{CRITTER_STYLE}{STYLE}{EXTRA}
body{{font:14px -apple-system,sans-serif;background:#f4f5f7;color:#222;padding:16px;max-width:1240px}}
h2{{margin:4px 0}} h3{{margin:18px 0 6px}} .grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(390px,1fr));gap:10px}}
section{{background:#fff;border-radius:10px;padding:8px 10px}} h4{{margin:2px 0}} .when{{margin:2px 0 4px;color:#B06A00;font-size:12px}}
.note{{margin:4px 0 0;color:#555;font-size:13px}} .say{{margin:4px 0 0;color:#2E6FB8;font-size:13px}} svg{{display:block}}
</style><h2>两只桌宠的新互动（12 种）</h2>
<p>静态草图，动画只做示意。台词由 DeepSeek 写，每个场景 3 组随机。所有互动都有冷却时间，不会一直打扰你；你在拖它们时不会触发。</p>
<h3>跟工作状态联动</h3><div class=grid>{"".join(cards[:4])}</div>
<h3>两只自己玩（都闲着时随机，平均 5～10 分钟一次）</h3><div class=grid>{"".join(cards[4:8])}</div>
<h3>跟你互动</h3><div class=grid>{"".join(cards[8:])}</div>'''
open(os.path.join(here, 'play-sketch.html'), 'w').write(html); print('ok', len(html))
