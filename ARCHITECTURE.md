# Architecture

How CatHerder works internally, and the non-obvious things learned building it.
For installation and usage, see [README.md](README.md).

Everything here is derived from data Claude Code already writes to disk. Nothing
is sent anywhere, and no Claude Code configuration is modified.

## Build and run

```bash
./build-app.sh --run          # release build, launch
./build-app.sh --install      # also copy into /Applications
./build-app.sh --debug        # faster compile while iterating
swift build                   # plain compile check
```

You can also open `Package.swift` in Xcode and run from there.

## What it shows

**Live Sessions** — one row per running `claude` process:

| Column | Source |
| --- | --- |
| Status | recent transcript writes + process CPU (see *Tuning* below) |
| Directory | the process's actual `cwd`, via `lsof` |
| Repo / Branch | read from `.git/HEAD` on disk; worktrees are labelled |
| Notion card | mined from the session's Notion tool calls |
| Recap | Claude Code's own generated session title |
| Activity | last transcript write, and process uptime |

Double-click a row (or right-click → Switch to Terminal Tab, or use the button
in the recap pane) to jump to that session's terminal.

**History** — every past session, with its recap, working directory, repo and
branch as of the last message, when it was last active, and two different
durations: *active for* (working time, excluding gaps over five minutes) and
*span* (first to last message).

Selecting any row opens a recap pane: the Notion card, pull requests opened,
recent instructions you gave, files changed, subagents launched, tools and
skills used, token count, and a copy-ready `--resume` command.

There is also a menu bar item showing the live instance count. Its popover
lists every instance it counts — directory, branch, recap, Notion card, last
activity and uptime — sized to fit them without scrolling. Clicking one jumps to
its terminal.

A status bar along the bottom of the list shows how many instances are working,
how many are waiting on you, and how many are running, plus indexing progress
and the filtered row count. Toggle it with ⌘/ (View → Hide/Show Status Bar); the
choice persists across launches.

The toolbar carries a filter field and a button to show or hide the recap pane.
There is no refresh button: the live view rescans every three seconds by itself,
and ⌘R forces a full refresh including a history re-index.

## How it works

Everything is derived from data Claude Code already writes locally. Nothing is
sent anywhere, and no Claude Code configuration is modified.

### Finding live instances

`ps` lists candidate processes; daemons, `bg-pty-host`, `bg-spare`, and the
`claude agents` launcher are filtered out. A single batched `lsof` call resolves
every working directory at once, and `ps eww` reads `TERM_PROGRAM` /
`TERM_SESSION_ID` out of each process's environment.

### Matching a process to its session

This is the one genuinely non-obvious part. Claude Code does not put its session
id in the process table, so `SessionResolver` uses a cascade, strongest evidence
first:

1. **Explicit** — `claude --resume <id>` names the session outright.
2. **Birth time** — Claude Code creates a per-session scratchpad directory
   (`/tmp/claude-<uid>/<slug>/<session-id>/`) at startup. Its creation time
   matches the process start time to within about a second, which makes it a
   reliable join key. `~/.claude/session-env/<session-id>` is used as a second
   source.
3. **Fallback** — the most recently modified transcript in that directory.

Each session is claimed by at most one process, so two instances in the same
directory never collide.

**Known limitation:** each process yields a single candidate. If two instances
share a directory and one names its session explicitly, the other's only
candidate may already be claimed, leaving it unresolved — the app then shows it
as a running instance with no transcript. Assigning it the next-newest transcript
would fill the row, but could attribute the wrong session, so it stays
unresolved. Covered by a test in `StatusAndResolverTests`.

### Reading transcripts

Sessions live as JSONL at `~/.claude/projects/<slugged-cwd>/<session-id>.jsonl`,
some of them tens of megabytes. `TranscriptParser` streams them line by line and
extracts the recap, timestamps, git branch, edited files, tool counts, PR links,
and Notion references.

Three details keep this fast enough to run over hundreds of files:

- Records are parsed inside a per-line `autoreleasepool`. Without it, the
  autoreleased Foundation objects from `JSONSerialization` accumulate until the
  whole corpus is resident — this alone accounted for ~180MB.
- Timestamps are parsed by hand rather than with `ISO8601DateFormatter`, which
  runs once per record and is neither fast nor `Sendable`.
- Digests are cached to `~/Library/Application Support/CatHerder/digests.json`
  keyed by file size and mtime, so unchanged transcripts are never re-read.

### Identifying the Notion card

Notion references are ranked by how strongly they imply real work:

- `confirmed` — a `notion-fetch` / `notion-update-page` response, which carries
  the authoritative page title.
- `toolCall` — a page id passed to a Notion tool.
- `slugURL` / `mention` — a link that merely appeared in text or command output.

Only `toolCall` and above count as "working on a card", so a session that
happens to print a Notion URL is not mislabelled. Where a session touches
several cards, the primary one is chosen by blending how often each was touched
with how well its title matches the session's own subject. Titles seen anywhere
are pooled across all transcripts, so a card referenced only by id in one
session can still be named from another.

### Switching to a terminal tab

The tty device is the join key: Terminal.app and iTerm2 both expose a `tty`
property on their tabs, so the exact tab can be addressed rather than guessed
from a window title. Other emulators (Ghostty, WezTerm, Warp, VS Code…) cannot
be driven tab-by-tab from AppleScript, so those are simply brought forward.

**First use will prompt for Automation permission.** Approve it, or grant it in
System Settings › Privacy & Security › Automation. The build script signs the
bundle ad-hoc with a stable identifier so the grant survives rebuilds.

Permission is checked *before* any event is sent, via
`AEDeterminePermissionToAutomateTarget`. This matters for more than tidiness:
macOS activates the target application as a side effect of delivering an Apple
Event even when it then refuses it, so simply sending the event and handling the
`-1743` error still yanked the terminal to the front on every denied attempt.
Asking first means a denial changes nothing on screen.

The call is synchronous and blocks while the consent dialog is up, so it runs off
the main thread — otherwise the window freezes behind the prompt.

The four answers map to distinct outcomes: granted (send the event), never asked
(raise the prompt, then act on the reply), denied (report it, and offer a button
that opens the Automation pane), and target not running (the tab is gone).

## Tests

```bash
swift test
```

103 tests across the parsing, correlation, git, status, Notion and formatting
logic. They run in about 0.03s and touch no real Claude Code data — transcripts,
git repositories and project trees are all built as fixtures in temp
directories, so the suite is safe to run on any machine.

`Tests/CatHerderTests/Fixtures.swift` composes JSONL records in the same shapes
Claude Code actually writes, which is what lets the parser tests exercise real
record structures rather than a simplified stand-in.

Three real bugs surfaced while writing them, all of which are now covered by
regression tests:

- URL patterns required a literal `/`, so any JSON producer that escapes
  forward slashes (`notion.so\/id`) defeated the Notion scan entirely.
- The same escaping issue in the Notion title warm-up pass.
- Vendor model prefixes were stripped only once, so `us.anthropic.claude-opus-5`
  displayed as "Claude" rather than "Opus 5".

## Visual review without Screen Recording permission

```bash
"build/CatHerder.app/Contents/MacOS/CatHerder" --snapshot /tmp/shots
```

The app drives itself through each view, writes PNGs, and exits. It renders its
own view hierarchy through AppKit, so it needs no Screen Recording grant and
works over SSH or in CI. Useful for catching layout regressions — every column
clipping bug in this app was found this way.

Two quirks are worth knowing, since they dictate how the capture is done:

- `cacheDisplay` renders AppKit-backed views (`Table`) faithfully, but not
  SwiftUI material surfaces — an inspector captured this way comes out blank.
  Those views are instead hosted in a throwaway `NSWindow` and captured from
  there.
- `ImageRenderer` is not a substitute: it renders neither `ScrollView` content
  nor `Button`s, so a recap pane comes out empty with placeholder marks.

## Tuning

`Sources/CatHerder/Services/SessionStatusPolicy.swift` decides whether an
instance reads as *Working*, *Needs you*, or *Idle*. It is the app's only
subjective rule — everything else is observation — so it is isolated in one
small function.

The current policy **biases toward Working**: a session reads as working unless
there is positive evidence it is waiting on you (Claude ended its turn and
said something). Anything still mid-turn stays Working however long it has been
quiet, because a long build or test run writes nothing to the transcript and is
otherwise indistinguishable from an abandoned session. The cost is an occasional
stale "Working"; the benefit is that "Needs you" stays trustworthy.

## Layout

```
Tests/CatHerderTests/            fixture builders + 103 tests
Tools/GenerateIcon.swift         draws the app icon at build time
Sources/CatHerder/
  CatHerderApp.swift          @main — window + menu bar scenes
  Models/Models.swift             domain types
  Services/
    ProcessScanner.swift          ps / lsof / process environment
    SessionStore.swift            transcript index, digest cache, PID→session
    TranscriptParser.swift        streaming JSONL parser
    GitInspector.swift            .git/HEAD reader (no git subprocess)
    TerminalActivator.swift       AppleScript tab focus
    SessionStatusPolicy.swift     status rule — tune this
    SnapshotRunner.swift          dev-only --snapshot capture
    FleetMonitor.swift            observable state, refresh loop
  Views/
    RootView.swift                navigation split view + inspector
    SearchField.swift             NSSearchField wrapper (orderable in toolbar)
    SessionTables.swift           live + history tables
    SessionDetailView.swift       recap pane
    MenuBarContent.swift          menu bar popover
    Formatters.swift              durations, paths, badges
```

## Icon

`Tools/GenerateIcon.swift` draws the icon at build time, so the repository
carries no binary assets. The glyph is three session rows with leading status
dots, mirroring the app's own list. Delete `build/AppIcon.icns` and rebuild to
redraw it.

## A note on toolbar layout

Three things about the macOS toolbar shaped this window, each learned the hard
way:

- `.searchable` installs its field at the trailing end, after every custom item,
  and that order cannot be changed — which drops it over the inspector. The
  filter is a wrapped `NSSearchField` placed as an ordinary toolbar item so it
  participates in normal ordering.
- Toolbar items right-align as one group, so there is no placement meaning
  "right edge of the list". Instead each control is declared on the view that
  owns its section: the section toggle and filter on the list, the inspector
  toggle on the inspector's content. The toolbar then splits at the column
  boundary. Faking the offset with a spacer does not work — macOS groups
  adjacent items into one rounded container, so an invisible spacer just
  stretches the group.
- The inspector's toolbar item stays put when the pane collapses, so it needs no
  fallback copy in the main toolbar; adding one renders two buttons.
- Leading (`.navigation`) items lay out *before* the window title, pushing it
  inline. Keeping the title in its normal place means using no navigation items.

## Notes

- Read-only with respect to Claude Code's data.
- The live view re-scans every 3 seconds; history is parsed in the background,
  newest first, and appears progressively.
- Transcripts with no messages (aborted launches) are hidden from history.
