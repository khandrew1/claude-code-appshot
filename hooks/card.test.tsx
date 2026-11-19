import { expect, test } from 'claude-code/testing'

const PNG = '/Users/someone/.claude/appshot/shots/20261118-180000-000-Safari.png'
const TXT = '/Users/someone/.claude/appshot/shots/20261118-180000-000-Safari.txt'

const SHOT = {
  id: '20261118-180000-000-Safari',
  app: 'Safari',
  title: 'Pull request #42',
  png: PNG,
  txt: TXT,
  chars: 12_400,
}

const BAND = {
  plugin: 'appshot',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isCollapsed: false,
    isWorking: false,
    maxRows: 20,
    bodyColumns: 80,
    scroll: { offset: 0, bodyRows: 19 },
    view: {},
  },
} as const

test('the card shows a capture and its ✕ takes it out of the box', async ($, on) => {
  let box = { text: `@${PNG} @${TXT}\n\nwhat is wrong here?`, cursor: 0 }
  box.cursor = box.text.length
  on('prompt.read', () => ({ value: box }))
  on('prompt.fill', (_, e) => {
    box = { text: e.text, cursor: e.cursor ?? e.text.length }
    return { isFilled: true }
  })

  // The engine's state store, holding one capture as the mod's atom tags it.
  let stored: unknown = { shape: 'attached-1', value: [SHOT] }
  let version = 1
  on('state.get', () => ({ value: { value: stored, version } }))
  on('state.set', (_, e) => {
    stored = e.value
    version += 1
    return { value: { isSet: true, version } }
  })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...BAND, surface })
    expect((await ui.find({ type: 'Text', text: /Safari/ }))?.text).toBe('Safari')
    expect(await ui.find({ type: 'Text', text: /Pull request/ })).toBeUndefined()
    await ui.unmount()
  }

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
  await ui.press({ key: `remove:${SHOT.id}` })
  await ui.unmount()

  expect(box.text).toBe('what is wrong here?')
  expect(stored).toEqual({ shape: 'attached-1', value: [] })
})

test('no card while nothing is attached', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /engine/ }))?.text).toBe('engine')
  await ui.unmount()
})
