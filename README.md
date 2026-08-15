# CatHerder

**A native macOS app for keeping track of every Claude Code session running on your machine.**

If you run Claude Code in more than one terminal tab, you have probably lost
track of which instance is doing what — which is waiting on you, which has been
grinding through a test suite for ten minutes, and which one you forgot about
entirely two days ago. CatHerder shows all of them in one window, and gets you
back to the right terminal tab in one click.

## Features

**Live sessions** — one row per running `claude` process:

| | |
| --- | --- |
| **Status** | Working, Needs you, or Idle |
| **Name** | the name you gave the session with `/rename` |
| **Directory** | the process's actual working directory |
| **Repo / branch** | read from `.git` on disk; linked worktrees are labelled |
| **Notion card** | which card the session is working on, if you use the Notion MCP |
| **Recap** | Claude Code's own generated session title |
| **Activity** | when the transcript was last written, and process uptime |

Double-click a row — or right-click, or use the button in the recap pane — to
**jump straight to that session's terminal tab**.

**History** — every past session, with its recap, working directory, the branch
it was actually working on, when it last ran, and two durations: *active for*
(working time, excluding gaps over five minutes) and *span* (first to last
message).

**Recap pane** — for any session: the Notion card, pull requests opened, the
recent instructions you gave, files changed, subagents launched, tools and skills
used, token count, and a copy-ready `claude --resume` command.

Columns can be dragged into whatever order you like and hidden from the header's
context menu; the arrangement is remembered per view across launches.

**Menu bar** — a live instance count, with a popover listing every session at a
glance. Click one to jump to its terminal.

## Requirements

- macOS 14 (Sonoma) or later
- Claude Code, having run at least once
- Xcode 15+ or a Swift 6 toolchain, to build from source

No third-party dependencies. No network access.

## Install

### From a release

Download the latest `CatHerder.zip` from
[Releases](https://github.com/danaspiegel/CatHerder/releases), unzip it, and drag
**Cat Herder.app** to `/Applications`.

Releases are ad-hoc signed rather than notarized, so macOS will block the first
launch. Right-click the app and choose **Open**, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/Cat Herder.app"
```

### From source

```bash
git clone https://github.com/danaspiegel/CatHerder.git
cd CatHerder
./build-app.sh --install --run
```

That compiles a release build, assembles `CatHerder.app`, and copies it into
`/Applications`. Other options:

```bash
./build-app.sh              # build only, into ./build
./build-app.sh --run        # build and launch
./build-app.sh --debug      # faster compile while iterating
swift build                 # plain compile check
swift test                  # run the test suite
```

You can also open `Package.swift` in Xcode and run from there.

### Permission for switching terminal tabs

The first time you use "Switch to Terminal Tab", macOS asks permission to
control your terminal via Apple Events. Approve it, or grant it later in **System
Settings → Privacy & Security → Automation**.

If no prompt ever appears and Cat Herder is missing from that Automation list,
the build is probably missing the `com.apple.security.automation.apple-events`
entitlement — the hardened runtime blocks Apple Events without it, and a blocked
event never raises a prompt. `codesign -d --entitlements - "/Applications/Cat Herder.app"`
should list it.

The other cause is launching *from a terminal*. Permission is granted to the
responsible process, and a terminal-launched app inherits the terminal's own
permission rather than getting its own — so nothing is asked and nothing is
listed. Launch it from Finder, Spotlight or `/Applications` instead. To see what
the app itself thinks:

```bash
"/Applications/Cat Herder.app/Contents/MacOS/CatHerder" --check-automation
```

Terminal.app and iTerm2 can be driven tab-by-tab. Other emulators (Ghostty,
WezTerm, Warp, VS Code, Alacritty, Hyper, Tabby) don't expose individual tabs to
AppleScript, so those are simply brought to the front.

## Keyboard shortcuts

| | |
| --- | --- |
| <kbd>⌘R</kbd> | refresh now (the live view also polls every 3 seconds) |
| <kbd>⌘/</kbd> | show or hide the status bar |

## Privacy

CatHerder is a local, read-only tool.

- It reads `~/.claude/projects/*.jsonl` (your session transcripts), the process
  table, and `.git/HEAD` in your working directories.
- It **makes no network requests whatsoever** — the Notion card titles are mined
  out of your own transcripts, not fetched from Notion.
- It never modifies Claude Code's data or configuration.
- Its only writes are a parsed-digest cache in
  `~/Library/Application Support/CatHerder/`.

Your transcripts contain everything you have ever said to Claude Code, so bear
that in mind before screenshotting the window: recaps, prompts, branch names and
card titles are all visible in the UI.

## How it works

Claude Code writes a JSONL transcript per session under
`~/.claude/projects/<slugged-cwd>/<session-id>.jsonl`. CatHerder streams those,
mines a digest from each, and correlates them with running processes.

The interesting part is that Claude Code does not put its session id in the
process table, so matching a running process to its transcript takes a cascade of
evidence — the strongest signal being that Claude Code creates a per-session
scratchpad directory whose birth time matches the process start time to within a
second.

[**ARCHITECTURE.md**](ARCHITECTURE.md) covers all of it: the correlation cascade,
the streaming parser and the performance work behind it, how the Notion card is
identified, the AppleScript tab lookup, and the macOS toolbar behaviours that
shaped the window.

## Caveats

**This is unofficial and not affiliated with Anthropic.** It reads Claude Code's
on-disk formats, which are internal and undocumented. A future Claude Code
release could change them and break parts of this app. Nothing it does is risky —
it only ever reads — but expect occasional maintenance.

Written against Claude Code 2.1.x.

## Development

```bash
swift test        # 103 tests, ~0.03s, no real Claude Code data required
```

Tests build transcripts, git repositories and project trees as fixtures in temp
directories, so the suite is safe to run anywhere.

There is also a screenshot tool that needs no Screen Recording permission — it
renders the app's own view hierarchy through AppKit:

```bash
"build/Cat Herder.app/Contents/MacOS/CatHerder" --snapshot /tmp/shots
```

The one rule worth knowing before changing behaviour: everything in the app is
plain observation except
[`SessionStatusPolicy.swift`](Sources/CatHerder/Services/SessionStatusPolicy.swift),
which decides whether a session reads as *Working* or *Needs you*. That is a
judgement call about how you work, and it is isolated in one small function so
you can tune it.

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening a
PR, and add a test when you fix a bug — the parser especially, where a
regression is easy to miss and hard to spot by eye.

CI builds, tests, and assembles the app bundle on every push and pull request.
Pushing a `v*` tag builds a release and publishes it with the zip attached:

```bash
git tag v1.0.1 && git push origin v1.0.1
```

## License

MIT — see [LICENSE](LICENSE).
