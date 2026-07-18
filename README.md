<p align="center">
  <img src="Resources/logo.svg" width="88" height="88" alt="Roundtable">
</p>

<h1 align="center">Roundtable</h1>

<p align="center"><b>One place in your menu bar for every AI coding session you're running.</b></p>


Roundtable watches your ongoing coding-agent sessions and tells you the moment
one needs you. It supports [Claude Code](https://docs.claude.com/en/docs/claude-code),
[Codex](https://github.com/openai/codex), [Pi](https://github.com/earendil-works/pi),
and [Oh My Pi](https://github.com/can1357/oh-my-pi), across whatever terminals you
use. When an agent finishes, asks a question, or blocks on a permission prompt,
you get a glanceable toast (it shows over full-screen apps too), and a click
takes you to that session's terminal.

It doesn't replace your harness or your terminal. It's a thin layer above them.
Once you're running three or four agents at once, the hard part isn't the work,
it's knowing which session is waiting. That's the problem Roundtable solves.

> **Status:** early but usable. macOS 14+. It reads your agents' own transcripts,
> so there's nothing to configure to get started. Per-display full-screen
> detection uses a private macOS API (details in [Privacy & caveats](#privacy--caveats)).

## Features

- Every harness in one attention-sorted list, with real session names (your
  renames, not random slugs).
- Only shows what's actually running. A session appears when a matching live
  process exists, matched to its transcript by working directory.
- Alerts that don't interrupt you: a toast in the menu-bar item, or a floating
  frosted-glass pill that shows over full-screen apps where the menu bar is
  hidden. On the focused screen or every screen, with an optional sound.
- Permission-prompt detection, the one thing reading transcripts can't do. A
  single toggle in Settings installs each harness's native hook so Roundtable
  knows the instant an agent is blocked waiting for your approval.
- Click a session to jump to its terminal or project workspace.

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
open Roundtable.app                 # look for the grid icon in the menu bar
```

`--scan` is the quickest way to see the engine work against your live sessions
without opening the GUI.

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
  running processes locally, and makes no network calls.
- It uses one private API: `CGSCopyManagedDisplaySpaces`, for per-display
  full-screen detection (the same call yabai and AltTab use). It's loaded through
  `dlsym`, so a future macOS that removes it degrades gracefully instead of
  crashing. This is also why Roundtable can't ship on the Mac App Store as-is.
- Enabling permission detection writes a hook into `~/.claude/settings.json`,
  `~/.codex/config.toml`, or `~/.omp/agent/hooks/`. Each original is backed up
  once before anything changes, and every toggle is reversible.
- `bundle.sh` ad-hoc-signs the app, so on first launch you may need to allow it
  in System Settings under Privacy & Security.

## Roadmap

- Exact-pane focus for muxy (over its socket) and cmux
- Reply to a session from the menu bar
- Multi-monitor focus refinements

## Contributing

Issues and PRs are welcome. Each harness is a self-contained `HarnessAdapter` of
around a hundred lines that tails a transcript into the shared `Session` model,
which makes adding a new one the easiest place to start. Please keep the build
warning-free (`swift build`).

## License

MIT. See [LICENSE](LICENSE).
