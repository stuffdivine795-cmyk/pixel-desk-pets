# Outfit sketch for the water drop, built on the approved drop generator
import importlib.util, sys, os
here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, 'sketch_drop.py')).read().split("EXTRA = ")[0]
sys.argv = ['x', os.path.join(here, 'sketch_base.py')]
ns = {}
exec(src, ns)
r, g, B, OX, STYLE = ns['r'], ns['g'], ns['B'], ns['OX'], ns['STYLE']
INK = B['ink']

def outfit(name):
    if name == 'duck':      # a rubber duck riding on the tip
        return (r(OX+4.6, -1.6, 5.4, 2, '#F7D33C') + r(OX+8.2, -3.4, 2.8, 2, '#F7D33C') +
                r(OX+11, -2.8, 1.2, 0.7, '#F29B38') + r(OX+9.8, -2.9, 0.5, 0.5, INK) + r(OX+4.2, -1.2, 0.8, 0.8, '#F7D33C'))
    if name == 'umbrella':  # a little umbrella as a hat
        return (r(OX+3.5, -4.2, 8, 1, '#E85D75') + r(OX+2.5, -3.2, 10, 1, '#E85D75') + r(OX+5.5, -3.2, 1, 1, '#FFFFFF') +
                r(OX+9.5, -3.2, 1, 1, '#FFFFFF') + r(OX+7.5, -4.2, 1, 1, '#FFFFFF') + r(OX+7.3, -2.2, 0.4, 2.4, '#3C4043') +
                r(OX+7.1, -5, 0.8, 0.8, '#3C4043'))
    if name == 'goggles':   # swimming goggles over the eyes
        return (r(OX+1.2, 7.6, 12.6, 0.5, '#2F6FB8') + r(OX+3.6, 7, 2.4, 2, '#1E2A44') + r(OX+3.8, 7.2, 2, 1.6, '#BFEFFF') +
                r(OX+9, 7, 2.4, 2, '#1E2A44') + r(OX+9.2, 7.2, 2, 1.6, '#BFEFFF') + r(OX+6, 7.6, 3, 0.4, '#1E2A44') +
                r(OX+4.6, 7.6, 0.5, 0.9, INK) + r(OX+9.9, 7.6, 0.5, 0.9, INK))
    if name == 'bucket':    # a fisherman's bucket hat
        return (r(OX+2.6, -0.2, 9.8, 0.8, '#C8A86B') + r(OX+4.2, -2, 6.6, 1.8, '#D9BC7E') + r(OX+4.2, -0.8, 6.6, 0.5, '#8B6B3D'))
    if name == 'ice':       # an ice-crystal crown
        return (r(OX+4.5, -1, 6, 1, '#8FD3F5') + r(OX+4.5, -2, 1, 1, '#8FD3F5') + r(OX+7, -2.8, 1, 1.8, '#B9E6FA') +
                r(OX+9.5, -2, 1, 1, '#8FD3F5') + r(OX+7.1, -0.8, 0.8, 0.6, '#3A8FD6'))
    if name == 'lotus':     # a lotus-leaf hat with a pink bud
        return (r(OX+2, -0.6, 11, 0.8, '#5BAA5B') + r(OX+3, -1.2, 9, 0.6, '#76C176') + r(OX+7.2, -2.6, 0.4, 1.4, '#3E8E3E') +
                r(OX+6.8, -3.8, 1.2, 1.2, '#F7A6B8') + r(OX+7, -4.4, 0.8, 0.6, '#F27E9C'))
    if name == 'ring':      # a swim ring around the middle
        return (r(OX-0.4, 10.4, 15.8, 1.8, '#F06A5A') + ''.join(r(OX+x, 10.4, 1.4, 1.8, '#FFFFFF') for x in (1.2, 6.8, 12.4)))
    return ''

NAMES = [('none', '素颜'), ('duck', '小黄鸭'), ('umbrella', '小雨伞'), ('goggles', '潜水镜'),
         ('bucket', '渔夫帽'), ('ice', '冰晶冠'), ('lotus', '荷叶帽'), ('ring', '游泳圈')]

def pet(name):
    inner = ns['drop']('idle') + ns['face']('idle', None) + ns['limbs']('idle', None)
    return (f'<svg viewBox="0 -60 220 220" width="220" height="220" shape-rendering="crispEdges" class="m-idle">'
            f'<rect x="50" y="152" width="140" height="2" fill="#000" opacity=".12"/><g class="pet">{inner}{outfit(name)}</g></svg>')

html = ['<!doctype html><meta charset=utf-8><title>Drop outfits</title><style>', STYLE,
        'body{font:14px -apple-system,sans-serif;background:#fff;color:#222;padding:16px;max-width:1000px}',
        '.grid{display:flex;flex-wrap:wrap;gap:12px}figure{margin:0;border:1px solid #eee;border-radius:8px;padding:6px;text-align:center}',
        '</style><h2>小水滴换装草图（8 套，水主题）</h2><div class=grid>']
html += [f'<figure>{pet(k)}<figcaption>{v}</figcaption></figure>' for k, v in NAMES]
html.append('</div>')
open(os.path.join(here, 'outfit-sketch.html'), 'w').write('\n'.join(html))
print('ok')
