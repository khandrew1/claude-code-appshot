import type { Register } from 'claude-code'

// One macOS helper per machine listens for the shortcut (it holds a lock), and
// writes each capture to ~/.claude/appshot/inbox. Every session running this mod
// polls the inbox; the live session the person used most recently claims each
// capture by renaming it into shots/, then mentions its files in the prompt box.

type Capture = {
  id: string
  app: string
  bundleId?: string
  title?: string
  url?: string
  png?: string
  txt: string
  chars: number
  at: number
}

type Presence = { id: string; at: number; beat: number }

const BEAT_MS = 5_000
const LIVE_MS = 20_000
const POLL_MS = 400
const STALE_MS = 120_000

const basename = (path: string) => path.slice(path.lastIndexOf('/') + 1)

export const register: Register = (on, options) => {
  const shortcut =
    typeof options.shortcut === 'string' && options.shortcut.trim()
      ? options.shortcut.trim().toLowerCase()
      : 'option+option'
  const focusClaude = options.focusClaude !== false
  const sound = options.sound !== false

  let root = ''
  let me = ''
  let claudePid = ''
  let bin: string | undefined
  let lastActive = 0
  let isClaiming = false
  let hasWarned = false
  let pending: Capture[] = []

  const dirs = () => ({
    inbox: `${root}/inbox`,
    shots: `${root}/shots`,
    sessions: `${root}/sessions`,
    bins: `${root}/bin`,
  })

  on('session.start', async ($, e, next) => {
    const started = await next(e)

    await $.command.register({
      name: 'appshot',
      description: 'Capture the window in front after a few seconds, or show what Appshot can do',
      argumentHint: '[seconds | status]',
    })

    const env = await $.process.hookEnv()
    const home = (await $.env.get('HOME')) ?? ''
    root = `${home}/.claude/appshot`
    me = env.CLAUDE_CODE_SESSION_ID ?? `pid-${env.CLAUDE_PID ?? Math.random()}`
    claudePid = env.CLAUDE_PID ?? ''
    lastActive = await $.clock.now()

    const { inbox, shots, sessions, bins } = dirs()
    await $.process.run(['/bin/mkdir', '-p', inbox, shots, sessions, bins])
    // Keep a week of captures; drop presence files of long-gone sessions.
    await $.process.run(['/usr/bin/find', shots, sessions, '-type', 'f', '-mtime', '+7', '-delete'])

    const beat = async () => {
      const presence: Presence = { id: me, at: lastActive, beat: await $.clock.now() }
      await $.fs.write(`${sessions}/${me}.json`, JSON.stringify(presence))
    }

    const isChosen = async () => {
      const now = await $.clock.now()
      let best: Presence = { id: me, at: lastActive, beat: now }
      for (const entry of await $.fs.list(sessions)) {
        if (entry.kind !== 'file' || !entry.name.endsWith('.json')) continue
        try {
          const other = JSON.parse(await $.fs.read(`${sessions}/${entry.name}`)) as Presence
          if (other.id === me || now - other.beat > LIVE_MS) continue
          if (other.at > best.at || (other.at === best.at && other.id > best.id)) best = other
        } catch {
          // a file mid-write or left by an older version: not a contender
        }
      }
      return best.id === me
    }

    const deliver = async (shot: Capture) => {
      const mentions = [shot.png && `@${shot.png}`, shot.chars > 0 && `@${shot.txt}`].filter(Boolean)
      if (mentions.length === 0) {
        $.ui.toast(
          `Appshot got nothing from ${shot.app}: Claude needs Screen Recording and Accessibility (run /appshot status).`,
        )
        return
      }
      const box = await $.prompt.read()
      const before = box.text.slice(0, box.cursor)
      const lead = before && !/\s$/.test(before) ? ' ' : ''
      const filled = await $.prompt.fill({ text: `${lead}${mentions.join(' ')} `, mode: 'insert' })
      if (!filled.isFilled) pending = [...pending, shot]
      await $.fs.write(
        `${root}/last-delivery.json`,
        JSON.stringify({ id: shot.id, session: me, isFilled: filled.isFilled, refusal: filled.refusal ?? null }),
      )

      const what = shot.title ? `${shot.app}: ${shot.title}` : shot.app
      $.ui.toast(
        filled.isFilled
          ? `Appshot of ${what} added to your prompt`
          : `Appshot of ${what} will go with your next message`,
      )
      if (focusClaude && bin && claudePid) void $.process.run([bin, 'activate', '--pid', claudePid])
    }

    const poll = async () => {
      if (isClaiming || !root) return
      isClaiming = true
      try {
        const names = (await $.fs.list(inbox))
          .filter(entry => entry.kind === 'file' && entry.name.endsWith('.json'))
          .map(entry => entry.name)
          .sort()
        if (names.length === 0 || !(await isChosen())) return

        for (const name of names) {
          // rename(2) is atomic: when two sessions race, one of the moves fails.
          const claimed = await $.process.run(['/bin/mv', `${inbox}/${name}`, `${shots}/${name}`])
          if (claimed.exitCode !== 0) continue
          const shot = JSON.parse(await $.fs.read(`${shots}/${name}`)) as Capture
          for (const key of ['png', 'txt'] as const) {
            const from = shot[key]
            if (!from) continue
            const to = `${shots}/${basename(from)}`
            const moved = await $.process.run(['/bin/mv', from, to])
            if (moved.exitCode === 0) shot[key] = to
          }
          if ((await $.clock.now()) - shot.at > STALE_MS) continue
          await deliver(shot)
        }
      } catch (error) {
        $.ui.log(`appshot: ${String(error)}`, { to: 'debug' })
      } finally {
        isClaiming = false
      }
    }

    let isBadShortcut = false

    const onLine = (line: string) => {
      let event: Record<string, unknown>
      try {
        event = JSON.parse(line) as Record<string, unknown>
      } catch {
        return
      }
      switch (event.event) {
        case 'captured':
          void poll()
          break
        case 'permissions': {
          const missing = [
            event.inputMonitoring === false && 'Input Monitoring',
            event.screenRecording === false && 'Screen Recording',
            event.accessibility === false && 'Accessibility',
          ].filter(Boolean)
          if (missing.length > 0 && !hasWarned) {
            hasWarned = true
            $.ui.toast(
              `Appshot needs ${missing.join(', ')} for Claude: System Settings › Privacy & Security. Restart Claude after granting.`,
            )
          }
          break
        }
        case 'listening':
          void (async () => {
            const key = `announced:${shortcut}`
            if (await $.store.get(key)) return
            await $.store.set(key, true)
            $.ui.toast(`Appshot is ready: press ${shortcut} in any app`)
          })()
          break
        case 'skipped':
          if (event.reason === 'front-is-claude') {
            $.ui.toast(`Appshot: switch to the window you want, then press ${shortcut}`)
          }
          break
        case 'error':
          if (event.reason === 'bad-shortcut') {
            isBadShortcut = true
            $.ui.toast(
              `Appshot does not understand "${shortcut}". Use option+option, command+command, or a chord like ctrl+shift+s.`,
            )
          }
          break
      }
    }

    const build = async (): Promise<string | undefined> => {
      const source = `${env.CLAUDE_PLUGIN_ROOT}/helper/appshot.swift`
      const sum = await $.process.run(['/usr/bin/shasum', '-a', '256', source])
      if (sum.exitCode !== 0) return undefined
      const target = `${bins}/appshot-helper-${sum.stdout.slice(0, 12)}`
      if (await $.fs.exists(target)) return target

      $.ui.toast('Appshot is building its macOS helper (first run, about 30 seconds)')
      const temp = `${target}.${me}.tmp`
      const built = await $.process.run(
        ['/usr/bin/xcrun', 'swiftc', '-O', '-swift-version', '5', '-o', temp, source],
        { timeoutMs: 300_000 },
      )
      if (built.exitCode !== 0) {
        $.ui.log(`appshot: swiftc failed\n${built.stderr}`, { to: 'debug' })
        $.ui.toast('Appshot could not build its helper: install the Xcode command line tools (xcode-select --install)')
        return undefined
      }
      await $.process.run(['/bin/mv', '-f', temp, target])
      return target
    }

    const listen = async (helper: string) => {
      const argv = [helper, 'listen', '--shortcut', shortcut, ...(sound ? [] : ['--silent'])]
      for (let attempt = 1; attempt <= 5; attempt++) {
        let buffer = ''
        try {
          for await (const piece of $.process.spawn({ argv })) {
            if (piece.stream !== 'stdout') continue
            buffer += piece.text
            for (let end = buffer.indexOf('\n'); end >= 0; end = buffer.indexOf('\n')) {
              onLine(buffer.slice(0, end))
              buffer = buffer.slice(end + 1)
            }
          }
        } catch (error) {
          $.ui.log(`appshot: helper stopped: ${String(error)}`, { to: 'debug' })
        }
        if (isBadShortcut) return
        await $.clock.sleep(2_000 * attempt)
      }
    }

    await beat()
    $.clock.every(BEAT_MS, () => void beat())
    $.clock.every(POLL_MS, () => void poll())

    void (async () => {
      bin = await build()
      if (bin) await listen(bin)
    })()

    return started
  })

  on('prompt.submit', async ($, e, next) => {
    // Only the person's own messages make this the session captures go to.
    const isPerson = ['composer', 'bridge', 'sdk'].includes(e.origin.kind)
    if (isPerson && !e.isMeta) lastActive = await $.clock.now()
    if (pending.length === 0 || e.isMeta || e.command || !isPerson) return next(e)

    const notes = pending.map(shot =>
      [
        `The person attached an Appshot of ${shot.app}${shot.title ? ` ("${shot.title}")` : ''}.`,
        shot.png ? `Screenshot: ${shot.png}` : undefined,
        shot.chars > 0 ? `Window text: ${shot.txt}` : undefined,
        'Read these files before answering.',
      ]
        .filter(Boolean)
        .join('\n'),
    )
    pending = []
    return next({ ...e, context: [...(e.context ?? []), ...notes] })
  }).catch(($, e, next) => next(e))

  on('command.run', { command: 'appshot' }, async ($, e) => {
    lastActive = await $.clock.now()
    if (!bin) return { text: 'Appshot is still building its helper. Try again in a moment.' }

    if (e.args.trim() === 'status') {
      const checked = await $.process.run([bin, 'permissions', '--prompt'])
      const status = JSON.parse(checked.stdout.trim().split('\n').pop() ?? '{}') as Record<string, boolean>
      const row = (name: string, isOn: boolean | undefined) => `- ${name}: ${isOn ? 'granted' : 'missing'}`
      return {
        text: [
          `Appshot shortcut: ${shortcut}`,
          row('Input Monitoring (hears the shortcut)', status.inputMonitoring),
          row('Screen Recording (the screenshot)', status.screenRecording),
          row('Accessibility (the window text)', status.accessibility),
          'Grant missing ones to Claude in System Settings › Privacy & Security, then restart Claude.',
        ].join('\n'),
      }
    }

    const seconds = Math.min(Math.max(Number(e.args.trim()) || 3, 1), 30)
    const helper = bin
    void (async () => {
      const ran = await $.process.run(
        [helper, 'capture', '--delay', String(seconds), ...(sound ? [] : ['--silent'])],
        { timeoutMs: (seconds + 20) * 1000 },
      )
      if (ran.stdout.includes('"skipped"')) {
        $.ui.toast('Appshot: Claude was still in front, so nothing was captured')
      }
    })()
    return { text: `Switch to the window you want. Appshot captures it in ${seconds} seconds.` }
  })
}
