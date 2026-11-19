# Appshot for Claude Code

Press a shortcut in any Mac app and the window in front lands in your Claude Code prompt: a screenshot plus the window's text, read through macOS Accessibility (including text scrolled out of view, where the app exposes it). Inspired by Appshots in the Codex app.

The default shortcut is **Option + Option**: hold both Option keys together.

## What's in here

- **The mod** (`hooks/register.ts`): a Claude Code plugin that starts the helper, picks up each capture, and inserts it into the prompt of the Claude session you used most recently.
- **The macOS helper** (`helper/appshot.swift`): a small Swift program that listens for the shortcut from any app, screenshots the window in front, and reads its text. The mod compiles it on first run.

## Requirements

- macOS
- Claude Code (terminal or the Claude desktop app)
- Xcode command line tools, for `swiftc`: `xcode-select --install`

## Install

At the prompt of a Claude Code terminal session:

```
/plugin install appshot --marketplace khandrew1/claude-code-appshot
```

Answer `y` to add the marketplace, then pick a scope (user scope makes it work in every session).

Or from a shell:

```bash
claude plugin install appshot --marketplace khandrew1/claude-code-appshot
```

## First run

1. Start a new Claude Code session. The mod builds its helper (about 30 seconds) and shows a toast when it starts.
2. macOS asks you to grant the app that runs Claude (Claude, or your terminal) three permissions in **System Settings › Privacy & Security**:
   - **Input Monitoring:** hears the shortcut from other apps
   - **Screen Recording:** takes the screenshot
   - **Accessibility:** reads the window's text
3. Run `/appshot status` to check all three show as granted. If the shortcut does nothing right after granting, restart Claude.
4. Switch to any app and press **Option + Option**. Claude comes to the front with the screenshot and the window text as `@` mentions in your prompt. Type your question and send.

## Usage

- **Shortcut:** captures the window in front and sends it to the Claude session you typed in last.
- **`/appshot [seconds]`:** captures whatever is in front after a delay (3 seconds by default). Handy for testing.
- **`/appshot status`:** shows the shortcut and which permissions are missing.

Pressing the shortcut while Claude itself is in front does nothing; switch to the window you want first.

## Settings

Change these in the plugin's config (`/config` in a terminal session):

| Setting | Default | What it does |
| --- | --- | --- |
| `shortcut` | `option+option` | Both keys of one modifier (`option+option`, `command+command`, `control+control`, `shift+shift`) or a chord such as `ctrl+shift+s` |
| `focusClaude` | `true` | Bring Claude to the front after a capture |
| `sound` | `true` | Play the macOS screenshot sound |

## Where captures go

Captures are saved in `~/.claude/appshot/shots` as a PNG and a text file per capture, and files older than a week are deleted when a session starts. With several Claude sessions open, one helper listens for all of them, and the session where you last sent a message gets the capture.

## Limits

- Web apps that draw their own canvas (Google Docs, Sheets, Slides) expose little text through Accessibility, so you mostly get the screenshot there.
- Screenshots are scaled down to at most 2400 pixels on the long side.
- Window text is capped at 60,000 characters.

## License

MIT
