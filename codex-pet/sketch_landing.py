# Landing-trick sketch v2: each trick as a 3-panel strip (falling, protected, landed)
import json, os, re, sys
here = os.path.dirname(os.path.abspath(__file__))
critters = dict(json.loads(l[5:]) for l in open(sys.argv[1]) if l.startswith('SVG>>'))
lines = json.load(open(os.path.expanduser('~/.claude/pet/landing-lines.json')))

src = open(os.path.join(here, 'sketch_drop.py')).read().split("EXTRA = ")[0]
sys.argv = ['x', os.path.join(here, 'sketch_base.py')]; ns = {}; exec(src, ns)
r, OX, STYLE, B = ns['r'], ns['OX'], ns['STYLE'], ns['B']
osrc = open(os.path.join(here, 'sketch_outfits.py')).read()
o = {}; exec(osrc[osrc.index('def outfit'):osrc.index('NAMES =')], {'r': r, 'OX': OX, 'INK': B['ink']}, o)
outfit = o['outfit']
drop = lambda mood='idle': ns['drop'](mood) + ns['face'](mood, None) + ns['limbs'](mood, None)

INK, RED, WHITE, GOLD, SKY, GREY, DARK = '#2B1D1A', '#E85D75', '#FFFFFF', '#F2C14E', '#7FB8E6', '#9AA0A6', '#3C4043'

CRITTER_STYLE = re.search(r'<style>(.*?)</style>', next(iter(critters.values())), re.S).group(1)

def body(svg):
    # drop the outer <svg> and the per-frame <style>; one copy of the styles goes in the page head
    svg = re.sub(r'<rect[^>]*opacity="\.12"/>', '', svg)
    return re.sub(r'<style>.*?</style>', '', re.sub(r'^<svg[^>]*>|</svg>\s*$', '', svg.strip()), flags=re.S)

def cr(x, y, w, h, c, cls=''):
    # a rect in the critter's cells (its frame puts cell 0,0 at 50,80)
    k = f' class="{cls}"' if cls else ''
    return f'<rect x="{(5+x)*10}" y="{(8+y)*10}" width="{w*10}" height="{h*10}" fill="{c}"{k}/>'

def critter(key, dy=0, cls=''):
    return f'<g transform="translate(0,{dy})" class="{cls}">{body(critters[key])}</g>'

def speed(x0, y0, n=3, length=3, rel=cr):
    # falling speed lines above the pet
    return ''.join(rel(x0 + i * 2.5, y0 - (i % 2), 0.3, length, '#BFC5CC') for i in range(n))

EXTRA = '''
.float { animation: float 1.6s steps(4) infinite; } @keyframes float { 0%,100% { transform: translateY(0) } 50% { transform: translateY(-8px) } }
.flick { animation: flick2 .2s steps(1) infinite; } @keyframes flick2 { 50% { opacity: 0 } }
.sway2 { animation: sway2 1.2s steps(2) infinite; } @keyframes sway2 { 0%,100% { transform: translateX(-4px) } 50% { transform: translateX(4px) } }
.drip2 { animation: drip2 .6s steps(3) infinite; } @keyframes drip2 { 0% { transform: none; opacity: 1 } 90% { opacity: 1 } 91%,100% { transform: translateY(18px); opacity: 0 } }
'''

def panel(content, ground_y=152, vb='-30 -110 300 290'):
    g = f'<rect x="-30" y="{ground_y}" width="300" height="3" fill="#D5D9DE"/>'
    return f'<svg viewBox="{vb}" width="210" height="203" shape-rendering="crispEdges">{g}{content}</svg>'

def strip(title, note, who, key, frames):
    ground_y = 144 if who == 'claude' else 151
    l = lines[who][key]
    cells = ''.join(f'<div class=cell><div class=step>{s}</div>{panel(svg, ground_y)}</div>' for s, svg in zip(['① 空中', '② 展开保护', '③ 落地'], frames))
    return (f'<section><h4>{title}</h4><p class=note>{note}</p><div class=strip>{cells}</div>'
            f'<p class=say>起跳：「{l["start"][0]}」 落地：「{l["land"][0]}」</p></section>')

# ---- 像素小橘 ----
falling = lambda key='up': critter(key, -60) + speed(1, -14) + speed(9, -13, 2)
landed = lambda key='idle': critter(key)
chute = (cr(3, -12, 8, 1, RED) + cr(1, -11, 12, 1, RED) + cr(0, -10, 14, 1.2, RED) +
         ''.join(cr(x, -10, 2, 1.2, WHITE) for x in (2, 6, 10)) + cr(5, -11, 2, 1, WHITE) +
         cr(0.5, -8.8, 0.3, 10.6, DARK) + cr(13.2, -8.8, 0.3, 10.6, DARK) + cr(4, -8.8, 0.3, 9, DARK) + cr(9.7, -8.8, 0.3, 9, DARK))
balloon = lambda x, y, c: (cr(x, y, 2, 2.4, c) + cr(x + 0.4, y - 0.4, 1.2, 0.4, c) + cr(x + 0.4, y + 0.4, 0.5, 0.6, WHITE) + cr(x + 0.8, y + 2.4, 0.4, 0.4, c))
bunch = balloon(12.6, -12, RED) + balloon(15, -13.6, GOLD) + balloon(13.8, -15.6, SKY) + cr(13.6, -9.2, 0.2, 11, DARK) + cr(15.9, -10.8, 0.2, 3, DARK) + cr(14.7, -12.8, 0.2, 5, DARK)
party = balloon(12.6, -12, '#F28FB1') + balloon(15, -13.6, '#5BD38A') + balloon(13.8, -15.6, '#B48CF2') + cr(13.6, -9.2, 0.2, 11, DARK) + cr(15.9, -10.8, 0.2, 3, DARK) + cr(14.7, -12.8, 0.2, 5, DARK) + \
        ''.join(cr(x, y, 0.6, 0.6, c, 'flick') for x, y, c in [(-2, -6, '#F28FB1'), (1, -9, GOLD), (16, -4, '#5BD38A')])
tramp = cr(-1, 6.6, 16, 0.6, DARK) + cr(-1, 6.4, 16, 0.3, '#5B7DB1') + cr(0, 7.2, 0.6, 1.4, GREY) + cr(13.4, 7.2, 0.6, 1.4, GREY) + cr(6.7, 7.2, 0.6, 1.4, GREY)
jet = (cr(-1.8, 0.4, 2, 3.4, GREY) + cr(-1.6, 0.2, 1.6, 0.4, DARK) + cr(-1.6, 3.8, 1.6, 1.4, '#F28C38', 'flick') + cr(-1.3, 5.2, 1, 1.2, GOLD, 'flick') +
       cr(-1.1, 6.4, 0.6, 0.8, '#FFF2B3', 'flick'))
box = cr(0, 3, 14, 4.4, '#C8935A') + cr(0, 3, 14, 0.6, '#A87542') + cr(-1.4, 2.2, 3, 0.8, '#C8935A') + cr(12.4, 2.2, 3, 0.8, '#C8935A') + cr(6.6, 3.6, 0.8, 3.8, '#E8C48A')
broom = cr(-3, 5.2, 18, 0.5, '#8B5A2B') + cr(-5, 4.6, 2.4, 1.6, GOLD) + cr(-5.4, 5, 0.6, 0.8, '#D9A93A') + cr(-6.4, 5.4, 0.6, 0.6, '#B48CF2', 'flick')

claude = [
    strip('降落伞', '中高处以上随机。撑开红白降落伞，左右飘着落地，落地后伞收起叠好', 'claude', 'parachute',
          [falling(), f'<g class="sway2">{critter("up", -40)}<g transform="translate(0,-40)">{chute}</g></g>', landed()]),
    strip('一串气球', '拽着三个气球慢慢降，落地后气球一个个飞走', 'claude', 'balloons',
          [falling(), f'<g class="float">{critter("up", -40)}<g transform="translate(0,-40)">{bunch}</g></g>', landed() + balloon(15, -9, SKY)]),
    strip('弹床', '落地前脚下冒出小弹床，弹两下再站稳，弹床收起', 'claude', 'trampoline',
          [falling(), tramp + critter('up', -50), tramp + critter('idle', -6)]),
    strip('喷气背包', '最高处落下时出现：背后点火减速，一路冒火慢慢降', 'claude', 'jetpack',
          [falling(), f'<g class="float">{critter("idle", -40)}<g transform="translate(0,-40)">{jet}</g></g>', landed()]),
    strip('纸箱缓冲', '地上冒出一个纸箱，掉进去，再从箱子里探出头', 'claude', 'box',
          [falling(), box + critter('up', -60), critter('idle', 6) + box.replace('#A87542', '#A87542')]),
    strip('骑扫帚（巫师帽专属）', '戴巫师帽时优先：骑上扫帚滑翔下来，带一串紫色火花', 'claude', 'broom',
          [falling('witchup'), f'<g class="float">{critter("witch", -40)}<g transform="translate(0,-40)">{broom}</g></g>', landed('witch')]),
    strip('派对气球（派对帽专属）', '戴派对帽时优先：彩色气球加彩带，落地撒一把彩纸', 'claude', 'party_balloons',
          [falling('partyup'), f'<g class="float">{critter("partyup", -40)}<g transform="translate(0,-40)">{party}</g></g>', landed('party') + party.split('<rect')[0]]),
]

# ---- 小水滴 ----
def dpanel(content):
    return panel(content, vb='-30 -110 300 290')
dfall = f'<g transform="translate(0,-60)">{drop()}</g>' + ''.join(r(OX + x, -9 - (i % 2), 0.3, 3, '#BFC5CC') for i, x in enumerate((3, 6, 9, 12)))
dland = drop()
puddle = (r(OX - 1.5, 13.6, 18, 1.4, '#6CC4F5') + r(OX - 0.5, 13, 16, 0.6, '#3A8FD6') + r(OX + 4.6, 13.9, 0.5, 0.5, B['ink']) + r(OX + 9.6, 13.9, 0.5, 0.5, B['ink']) +
          ''.join(r(OX + x, y, 0.8, 1, '#6CC4F5', 'drip2') for x, y in [(-3, 9), (0, 7), (14, 7), (17, 9), (7, 6)]))
cloud = (r(OX + 1, 2, 13, 4, '#DDE6EE') + r(OX + 3, 0.6, 9, 1.6, '#DDE6EE') + r(OX, 3, 1, 2, '#DDE6EE') + r(OX + 14, 3, 1, 2, '#DDE6EE') +
         r(OX + 4.6, 3.4, 0.5, 0.9, B['ink']) + r(OX + 9.6, 3.4, 0.5, 0.9, B['ink']) + r(OX + 7, 4.6, 1, 0.3, B['ink']) +
         ''.join(r(OX + x, 6.4, 0.3, 0.8, '#3A8FD6', 'drip2') for x in (2.5, 5, 7.5, 10, 12.5)))
ring = ''.join(r(OX - 2 + x, -2 + y, 1, 1, '#8FC7EA') for x, y in
               [(i, 0) for i in range(5, 15)] + [(i, 19) for i in range(5, 15)] + [(0, i) for i in range(5, 15)] + [(19, i) for i in range(5, 15)] +
               [(1, 3), (2, 2), (3, 1), (4, 1), (15, 1), (16, 1), (17, 2), (18, 3), (1, 16), (2, 17), (3, 18), (4, 18), (15, 18), (16, 18), (17, 17), (18, 16), (1, 4), (18, 4), (1, 15), (18, 15)]) + r(OX + 1, 0.6, 1.2, 1.2, WHITE)
pop = ''.join(r(OX + x, y, 0.8, 0.8, '#8FC7EA') for x, y in [(-2, 2), (0, -1), (14, -1), (17, 2), (-3, 8), (18, 8)])
big_umbrella = (r(OX + 1, -6.4, 13, 1, RED) + r(OX - 0.5, -5.4, 16, 1, RED) + r(OX - 1.5, -4.4, 18, 1, RED) +
                ''.join(r(OX + x, -4.4, 2, 1, WHITE) for x in (1, 6.5, 12)) + r(OX + 7.3, -3.4, 0.4, 3.6, DARK) + r(OX + 7.1, -7.2, 0.8, 0.8, DARK))
leaf = r(OX - 3, -2.4, 21, 1, '#5BAA5B') + r(OX - 1.5, -3.2, 18, 0.8, '#76C176') + r(OX + 7.2, -1.4, 0.4, 1.6, '#3E8E3E') + r(OX + 6.8, -4.4, 1.2, 1.2, '#F7A6B8')
wings = r(OX + 2.4, -3.4, 2, 0.8, '#F7D33C', 'flick') + r(OX + 11, -3.4, 2, 0.8, '#F7D33C', 'flick') + r(OX + 2.4, -2.6, 2, 0.8, '#E8C02C') + r(OX + 11, -2.6, 2, 0.8, '#E8C02C')
ice = (''.join(r(OX - 1.5 + x, -0.5 + y, 1, 1, '#8FD3F5') for x, y in [(i, 0) for i in range(18)] + [(i, 16) for i in range(18)] + [(0, i) for i in range(17)] + [(17, i) for i in range(17)]) +
       r(OX, 1, 2, 0.6, WHITE) + r(OX, 1.6, 0.6, 2, WHITE))
slide = ''.join(r(OX + x, 14.6, 2, 0.3, '#BFC5CC') for x in (-6, -3.5, -9))

codex = [
    strip('落地成水', '中高处随机。直接摔成一滩水、溅起水花，再咕噜一下聚回水滴', 'codex', 'splash', [dfall, puddle, dland + r(OX - 1, 14.4, 17, 0.5, '#9FD8F5')]),
    strip('变成小雨云', '在空中蒸发成一朵小雨云，下着小雨飘下来，再凝回水滴', 'codex', 'cloud', [dfall, f'<g class="float">{cloud}</g>', dland]),
    strip('泡泡', '把自己裹进大泡泡里慢慢飘，落地啵地破掉', 'codex', 'bubble', [dfall, f'<g class="float" transform="translate(0,-30)">{drop()}{ring}</g>', dland + pop]),
    strip('撑伞（小雨伞专属）', '戴小雨伞时优先：伞变大撑开，像蒲公英一样慢慢飘下', 'codex', 'umbrella',
          [f'<g transform="translate(0,-60)">{drop()}{outfit("umbrella")}</g>', f'<g class="sway2" transform="translate(0,-40)">{drop()}{big_umbrella}</g>', dland + outfit('umbrella')]),
    strip('荷叶滑翔（荷叶帽专属）', '戴荷叶帽时优先：荷叶展开当滑翔伞，斜着飘到地面', 'codex', 'lotus',
          [f'<g transform="translate(0,-60)">{drop()}{outfit("lotus")}</g>', f'<g class="sway2" transform="translate(-20,-40)">{drop()}{leaf}</g>', dland + outfit('lotus')]),
    strip('小鸭拍翅膀（小黄鸭专属）', '戴小黄鸭时优先：小鸭张开翅膀扑腾，拎着它降落', 'codex', 'duck',
          [f'<g transform="translate(0,-60)">{drop()}{outfit("duck")}</g>', f'<g class="float" transform="translate(0,-40)">{drop()}{outfit("duck")}{wings}</g>', dland + outfit('duck')]),
    strip('冻成冰块（冰晶冠专属）', '戴冰晶冠时优先：冻成小冰块落地，在地上滑一段再化开', 'codex', 'ice',
          [f'<g transform="translate(0,-60)">{drop()}{outfit("ice")}</g>', f'<g transform="translate(0,-10)">{drop()}{ice}</g>', f'<g transform="translate(30,0)">{dland}{outfit("ice")}</g>' + slide]),
]

html = f'''<!doctype html><meta charset=utf-8><title>Landing tricks v2</title><style>{CRITTER_STYLE}{STYLE}{EXTRA}
body{{font:14px -apple-system,sans-serif;background:#f4f5f7;color:#222;padding:16px;max-width:1100px}}
h2{{margin:4px 0}} h3{{margin:18px 0 6px}} section{{background:#fff;border-radius:10px;padding:8px 12px;margin:8px 0}}
h4{{margin:2px 0}} .note{{margin:2px 0 6px;color:#666;font-size:13px}} .say{{margin:4px 0 0;color:#2E6FB8;font-size:13px}}
.strip{{display:flex;gap:6px}} .cell{{border:1px solid #eee;border-radius:6px;position:relative}} .step{{position:absolute;left:6px;top:4px;font-size:12px;color:#999}}
</style><h2>从高处放手时的落地方式 v2</h2>
<p>拎起来松手时按高度决定：不到 80pt 普通落地；中等高度小橘弹一下、小水滴溅一下；很高时从下面随机挑一种（戴着对应装扮时优先用专属的），起跳和落地各喊一句（DeepSeek 写的，每种 3 句随机）。</p>
<h3>像素小橘（7 种）</h3>{''.join(claude)}<h3>小水滴（7 种）</h3>{''.join(codex)}'''
open(os.path.join(here, 'landing-sketch.html'), 'w').write(html); print('ok')
