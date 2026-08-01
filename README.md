<p align="center">
  <img src="Resources/logo.svg" width="88" height="88" alt="Roundtable">
</p>

<h1 align="center">Roundtable</h1>

<p align="center"><b>Every AI coding session you're running, one glance away.</b></p>


Roundtable is a small glass dot you drop anywhere on your screen. It watches your
ongoing coding-agent sessions and tells you the moment one needs you. It supports
[Claude Code](https://docs.claude.com/en/docs/claude-code),
[Codex](https://github.com/openai/codex), [Pi](https://github.com/earendil-works/pi),
and [Oh My Pi](https://github.com/can1357/oh-my-pi), across whatever terminals you
use.

At rest the dot tucks against a screen edge and stays out of your way. When an
agent finishes or blocks on a permission prompt, it stretches out into a line
telling you which one, then tucks back. Click it and it opens into the full
session list, in place. It draws over full-screen apps, so it reaches you
wherever you are.

It doesn't replace your harness or your terminal. It's a thin layer above them.
Once you're running three or four agents at once, the hard part isn't the work,
it's knowing which session is waiting. That's the problem Roundtable solves.

> **Status:** early but usable. macOS 14+. It reads your agents' own transcripts,
> so there's nothing to configure to get started. The menu-bar presentation still
> exists in the code and works, it just isn't the one offered in Settings. Per-display full-screen
> detection uses a private macOS API (details in [Privacy & caveats](#privacy--caveats)).

## Features

- **A floating orb, not a menu-bar item.** Drag it anywhere; it tucks against
  the nearest edge and sits over full-screen apps. Alerts grow out of it right
  where you're already looking.
- **Every harness in one attention-sorted list**, with real session names (your
  renames, not random slugs).
- **Answer without switching.** When an agent blocks on a permission prompt, the
  row shows the exact command with Allow and Deny. Roundtable types the answer
  into that terminal for you, and the terminal stays answerable too.
- **Keyboard shortcuts for all of it.** Open the list, jump to whatever is
  waiting, approve or deny, or go straight to the third session, without
  touching the mouse. All rebindable in Settings.
- **Peek before you switch.** Expand a session to read its recent activity in
  place; most of the time that answers the question.
- **Only shows what's actually running.** A session appears when a matching live
  process exists, matched to its transcript by working directory.
- **Permission-prompt detection**, the one thing reading transcripts can't do. A
  single toggle in Settings installs each harness's native hook.
- **Updates itself.** Checks this repo's releases twice a day and offers a
  one-click update in the orb when a new version is out.

## Supported harnesses

| Harness | State + last line | Session name | Permission prompts |
|---|---|---|---|
| Claude Code | transcript | rename, AI title, slug | `Notification` hook |
| Codex | transcript | `session_index.jsonl` | `PermissionRequest` hook |
| Oh My Pi | transcript | in-transcript title | `tool_approval_requested` extension |
| Pi | transcript | in-transcript title | shares omp's extension API |

"Waiting" and "working" come from tailing each harness's own transcript, with no
setup. Permission prompts aren't written to those transcripts, so they're
detected through each harness's hook instead. That part is opt-in, installs with
one toggle, and every config it edits is backed up first.

## Build & run

Requires macOS 14+ and a Swift 6 toolchain (Xcode 16+).

```bash
swift build                         # compile
./.build/debug/Roundtable --scan    # headless: print current sessions, then exit
./scripts/bundle.sh                 # assemble and ad-hoc-sign Roundtable.app
open Roundtable.app                 # look for the dot tucked against a screen edge
```

`--scan` is the quickest way to see the engine work against your live sessions
without opening the GUI.

A locally built app is ad-hoc signed, so macOS asks you to allow it once under
System Settings → Privacy & Security. (Released downloads are notarized and
open directly.)

## How it works

It comes down to a single join. On one side, each harness's transcript tells you
a session's state, last line, name, and working directory. On the other, the
running processes tell you which sessions are live, in which terminal. Match them
on the working directory and you have everything you need to show a session,
alert on it, and focus it.

```
DISK  (harness transcript)  ─┐   state · last line · name · cwd
                             ├─ join on cwd ─▶  Session  ─▶  menu · toast · focus
PROC  (running processes)   ─┘   live PID · owning terminal · injected pane env
```

- **`Engine/`** holds `SessionStore`, which polls each `HarnessAdapter` off the
  main thread and normalizes everything to one `Session` type. It fires a toast
  only on the transition into an attention state. Adapters tail the transcript
  rather than reading whole files, and cache by mtime, so an idle session isn't
  re-parsed every tick.
- **`Focus/`** finds the live harness process for a session's working directory
  (via a libproc syscall, no `lsof`), its owning terminal, and the per-pane
  environment variable the terminal injects. `FullScreenDetector` maps the
  private Spaces API onto each screen, and `FocusEngine` raises the right
  terminal or muxy workspace. The hook installers live here too.
- **`UI/`** is an AppKit `NSStatusItem` (custom-drawn) plus a floating `NSPanel`
  that can render over full-screen apps, a queue so a burst of alerts plays
  cleanly, and a SwiftUI settings panel.

### Two parsing rules worth knowing

Both once caused sessions to silently disappear, and both now live in
`TailReader`:

1. Don't trust the last line to carry metadata. The final record is often a
   bookkeeping entry with none of the fields you want, so search backwards.
2. Decode chunks lossily. A fixed-size tail window can split a multi-byte UTF-8
   character; strict decoding returns nil and drops the whole session.

## Terminal focus

Clicking a session focuses its terminal. How precisely depends on what the
terminal lets you script:

| Terminal | Precision | Mechanism |
|---|---|---|
| iTerm2 | exact split | API / AppleScript, tty then activate |
| tmux | exact pane | `select-pane` on `TMUX_PANE`, raise host |
| muxy | project workspace | `muxy <cwd>` (exact pane over the socket is planned) |
| cmux | surface | socket `focus-panel` (planned) |
| Ghostty | window | AppleScript (no PID-to-split mapping) |
| other | window | Accessibility raise |

## Privacy & caveats

- Everything stays on your machine. Roundtable reads on-disk transcripts and
  running processes locally, and sends nothing anywhere — no telemetry, no
  accounts, no analytics.
- It uses one private API: `CGSCopyManagedDisplaySpaces`, for per-display
  full-screen detection (the same call yabai and AltTab use). It's loaded through
  `dlsym`, so a future macOS that removes it degrades gracefully instead of
  crashing. This is also why Roundtable can't ship on the Mac App Store as-is.
- Enabling permission detection writes a hook into `~/.claude/settings.json`,
  `~/.codex/config.toml`, or `~/.omp/agent/hooks/`. Each original is backed up
  once before anything changes, and every toggle is reversible.
- The update check asks this repo's GitHub releases for the latest version
  number, twice a day, and nothing else. Turn it off entirely with
  `defaults write dev.rahulkrishna.roundtable automaticUpdateChecks -bool false`.

## Shortcuts

All global, all rebindable in Settings (click the shortcut, press the keys you
want; Escape cancels, Delete clears). A combination another app already owns
won't register.

| Shortcut | Does |
|---|---|
| `⌘⌥R` | Open / close the session list |
| `⌘⌥J` | Jump to the session that needs you |
| `⌘⌥Y` | Approve the pending prompt |
| `⌘⌥N` | Deny the pending prompt |
| `⌘⌥O` | Show / hide the orb |
| `⌘⌥1`–`⌘⌥9` | Jump straight to the Nth session |

Approve and deny work with the list closed, which is the point: you never have
to leave what you're doing.

## Roadmap

- Exact-pane focus for cmux
- Reply to a session inline, without switching to its terminal
- Multi-monitor focus refinements

## Contributing

Issues and PRs are welcome. Each harness is a self-contained `HarnessAdapter` of
around a hundred lines that tails a transcript into the shared `Session` model,
which makes adding a new one the easiest place to start. Please keep the build
warning-free (`swift build`).

**Reporting a bug?** Attach a debug log — it records the decision points
(session states, what was announced and why, hook events, focus and injection
attempts), which is usually the difference between a fix and a guess:

```sh
defaults write dev.rahulkrishna.roundtable debugLogging -bool true
# relaunch Roundtable, reproduce the problem, then attach:
#   ~/Library/Logs/Roundtable/debug.log
defaults delete dev.rahulkrishna.roundtable debugLogging   # turn it back off
```

Nothing is logged unless you set the flag, and nothing ever leaves your machine
on its own. The log does contain your project names and paths — skim it before
attaching.

## License

MIT. See [LICENSE](LICENSE).
