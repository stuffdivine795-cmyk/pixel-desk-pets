import { expect, test } from 'claude-code/testing'

const PANE = {
  plugin: 'slime-pet',
  component: 'Pane',
  requestId: 'slime-pet',
  props: {
    title: '像素小橘',
    isFocused: false,
    bodyColumns: 40,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 20 },
    view: {},
  },
} as const

test('the slime works through a tool call, then thinks again', async ($, on) => {
  const written: string[] = []
  on('command.register', () => ({ value: { command: 'pet' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('env.get', () => ({ value: '/home/test' }))
  on('fs.read', () => { throw new Error('ENOENT') })
  on('fs.list', () => ({ value: [] }))
  on('session.id', () => ({ value: 'test-session' }))
  on('fs.write', (_, e) => { written.push(e.text); return { value: undefined } })
  on('clock.now', () => ({ value: 1_000_000 }))
  on('clock.after', () => ({ value: { cancel: () => {} } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: {} }))

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(written.some(t => t.includes('"working"') && t.includes('Bash') && t.includes('"outfit":"witch"'))).toBe(true)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /思考中/ }))?.text).toContain('思考中')
    expect(await ui.find({ type: 'Button', key: 'poke' })).toBeDefined()
    await ui.unmount()
  }
})

test('the quota reaches the desktop pet and the pane', async ($, on) => {
  const written: string[] = []
  on('command.register', () => ({ value: { command: 'pet' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('env.get', () => ({ value: '/home/test' }))
  on('fs.read', () => { throw new Error('ENOENT') })
  on('fs.list', () => ({ value: [] }))
  on('session.id', () => ({ value: 'test-session' }))
  on('fs.write', (_, e) => { written.push(e.text); return { value: undefined } })
  on('clock.now', () => ({ value: Date.parse('2026-11-02T12:00:00Z') }))
  on('clock.after', () => ({ value: { cancel: () => {} } }))
  on('clock.every', () => ({ value: { cancel: () => {} } }))
  on('session.usage', () => ({ value: { startedAt: 0, context: {}, rateLimits: [
    { kind: 'five_hour', percentUsed: 36, resetsAt: '2026-11-02T14:30:00Z' },
    { kind: 'seven_day', percentUsed: 5, resetsAt: '2026-11-09T07:00:00Z' },
  ] } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  expect(written.some(t => t.includes('"five_hour":{"used":36'))).toBe(true)

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /5 小时剩 64%/ }))?.text).toContain('每周剩 95%')
  await ui.unmount()
})

test('the desktop pet shows the busiest session', async ($, on) => {
  const files: Record<string, string> = {
    '/home/test/.claude/pet/sessions/other.json': JSON.stringify({ state: 'working', detail: 'Edit', ts: 1_000_000 - 60 }),
    '/home/test/.claude/pet/sessions/old.json': JSON.stringify({ state: 'working', detail: 'Bash', ts: 1_000_000 - 3600 }),
  }
  on('command.register', () => ({ value: { command: 'pet' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('env.get', () => ({ value: '/home/test' }))
  on('session.id', () => ({ value: 'me' }))
  on('fs.read', (_, e) => { if (files[e.path] === undefined) throw new Error('ENOENT'); return { value: files[e.path] } })
  on('fs.write', (_, e) => { files[e.path] = e.text; return { value: undefined } })
  on('fs.list', () => ({ value: Object.keys(files).filter(f => f.includes('/sessions/')).map(f => ({ name: f.split('/').pop(), kind: 'file', size: 1, mtimeMs: 0, isLink: false })) }))
  on('clock.now', () => ({ value: 1_000_000_000 }))
  on('clock.after', () => ({ value: { cancel: () => {} } }))
  on('clock.every', () => ({ value: { cancel: () => {} } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('turn.complete', () => ({ text: 'ok' }))

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  // This session is idle, another is working: the desktop shows the work
  const shown = JSON.parse(files['/home/test/.claude/pet/state.json'] ?? '{}')
  expect(shown.state).toBe('working')
  expect(shown.detail).toBe('Edit')
})

for (const suffix of ['.000Z', 'Z']) {
  test(`2% quota keeps the pane's SVG and pixel battery (${suffix})`, async ($, on) => {
    on('command.register', () => ({ value: { command: 'pet' } }))
    on('ui.open', () => ({ value: { isPlaced: true } }))
    on('env.get', () => ({ value: '/home/test' }))
    on('fs.read', () => { throw new Error('ENOENT') })
    on('fs.list', () => ({ value: [] }))
    on('session.id', () => ({ value: 'test-session' }))
    on('fs.write', () => ({ value: undefined }))
    on('clock.now', () => ({ value: Date.parse('2026-11-02T12:00:00Z') }))
    on('clock.after', () => ({ value: undefined }))
    on('clock.every', () => ({ value: undefined }))
    on('session.usage', () => ({ value: { startedAt: 0, context: {}, rateLimits: [
      { kind: 'five_hour', percentUsed: 98, resetsAt: `2026-11-02T14:30:00${suffix}` },
      { kind: 'seven_day', percentUsed: 13, resetsAt: `2026-11-09T07:00:00${suffix}` },
    ] } }))
    on('session.start', (_, e) => ({ cwd: e.cwd }))
    on('tool.call', () => ({ result: {} }))

    await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
    await $.tool.call({ tool: 'Bash', command: 'ls' })
    const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
    expect((await ui.find({ type: 'Text', text: /5 小时剩 2%/ }))?.text).toContain('每周剩 87%')
    const tree = await ui.drawn()
    const picture = tree.children?.find(node => typeof node === 'object' && node !== null && node.type === 'Svg')
    if (typeof picture !== 'object' || picture === null || picture.type !== 'Svg') throw new Error('pane lost its SVG')
    const source = picture.props.source
    expect(source.startsWith('<svg xmlns="http://www.w3.org/2000/svg"')).toBe(true)
    expect(source.endsWith('</svg>')).toBe(true)
    expect(source.length < 131072).toBe(true) // SDK's documented Svg limit
    expect(/NaN|Infinity|undefined/.test(source)).toBe(false)
    const rects = [...source.matchAll(/<rect\b([^>]*)\/>/g)]
    expect(rects.some(([, attrs]) => attrs.includes('width="100"') &&
      attrs.includes('height="50"') && attrs.includes('fill="#D97757"'))).toBe(true) // visible body
    for (const [, attrs] of rects) {
      for (const key of ['x', 'y', 'width', 'height']) {
        const value = attrs.match(new RegExp(`\\b${key}="([^"]+)"`))?.[1]
        expect(value).toBeDefined()
        expect(Number.isFinite(Number(value))).toBe(true)
        if (key === 'width' || key === 'height') expect(Number(value) > 0).toBe(true)
      }
    }
    const segments = rects.filter(([, attrs]) => attrs.includes('y="10"') && attrs.includes('height="12"'))
    expect(segments.filter(([, attrs]) => attrs.includes('fill="#D8453B"')).length).toBe(1)
    expect(segments.filter(([, attrs]) => attrs.includes('fill="#E4E4E4"')).length).toBe(3)
    // The 3x5 glyphs for "2%" contain eleven and seven lit pixels respectively.
    // 2% left: 18 red digit dots, plus the one lit red charge segment
    expect(rects.filter(([, attrs]) => attrs.includes('fill="#D8453B"')).length).toBe(19)
    await ui.unmount()

    const terminal = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await terminal.find({ type: 'Svg' })).toBeUndefined()
    expect((await terminal.find({ type: 'Text', text: '( ･ω･)…' }))?.text).toContain('( ･ω･)…')
    await terminal.unmount()
  })
}
