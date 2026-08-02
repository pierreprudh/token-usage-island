<div align="center">

# Token Usage Island

**Your AI-coding plan limits, live in the notch.**

A native macOS notch HUD that shows how much of your **Claude**, **Codex**, and **OpenCode**
usage you've burned — without opening a single app.

<br />

![Token Usage Island — hover, expand, and reorder](docs/demo.gif)

<br />

<sub>Hover the notch for the at-a-glance lip — no click needed:</sub>

![The hover lip — Claude's 5 h and weekly rates](docs/hover.png)

<br />

![Platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple&logoColor=white)
&nbsp;![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift&logoColor=white)
&nbsp;![UI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-blue)
&nbsp;![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
&nbsp;![License](https://img.shields.io/badge/license-MIT-lightgrey)

</div>

---

## Overview

Token Usage Island lives in the MacBook notch. At rest it's invisible — a black tab flush
with the notch. **Hover** and it springs open to reveal your Claude session and weekly usage;
**click** and it expands into a Control-Center-style card with a full breakdown for all three
tools. **Drag** a row to reorder which tool leads the summary.

It sizes itself to **your Mac's actual notch** — read live from the display at launch
(`safeAreaInsets` + the menu-bar auxiliary areas) — so it fits the 14″/16″ MacBook Pro and the
13″/15″ MacBook Air alike, and re-measures when you change display scaling or move it to a
screen without a notch (where it falls back to a floating card).

## Features

- **Glanceable** — hover reveals both Claude rates (`47% 5h · 6% 7d`), colour-coded by severity.
- **Three tools, one place** — Claude, Codex, and OpenCode side by side.
- **Reorderable** — drag any row to choose which tool the collapsed lip summarises.
- **Native & lightweight** — SwiftUI + AppKit, a single borderless panel, zero dependencies.
- **Private by design** — reads local files and your own Keychain token; the only network
  call goes straight to Anthropic with your own credentials.
- **On-demand** — no background polling; it fetches at launch, on expand, and when your
  coding tools write new data.
- **Fluid** — Apple-style spring reveals, a glassy launch greeting, and live milestone pulses
  as usage crosses each 10% band.

## What it shows

| Tool | Source | Metric |
|------|--------|--------|
| **Claude** | Live `GET /api/oauth/usage` (OAuth token from the Keychain) | Session (5 h) % + Weekly %, with reset times — the same data as `/usage` |
| **Codex** | Latest `rate_limits` event in `~/.codex/sessions/**/*.jsonl` | Weekly % + plan, as of your last Codex run |
| **OpenCode** | `~/.local/share/opencode/opencode.db` (SQLite) | Spend + tokens this week — pay-as-you-go, so no plan cap |

## Install

### Homebrew (recommended)

```bash
brew install --cask --no-quarantine pierreprudh/tap/token-usage-island
usage island   # launch from anywhere
```

The cask puts a `usage` command on your `PATH` (with `<TAB>` completion in zsh), so you can
control the app from any terminal:

```bash
usage island     # launch the app
usage status     # print the numbers here in the terminal — no GUI
usage off        # turn it off       (aliases: quit, stop)
usage restart    # relaunch it
usage version    # print the installed version
usage help       # show all commands
```

### `usage status` — the numbers without the island

Same three providers, read the same way, printed instead of drawn. Works whether or not
the app is running, and on any Mac — no notch required.

```
$ usage status
Claude  Team plan
  Session · 5h  ████░░░░░░░░░░░░░░░░  20%   Resets 03:10
  Weekly        █░░░░░░░░░░░░░░░░░░░  3%    Resets Sun 06:00

Codex  Plus plan
  Weekly        ██░░░░░░░░░░░░░░░░░░  9%    Resets Sun 22:22

OpenCode  pay-as-you-go
  This week                                 $0.84 · 11.7M tok
```

| Flag | Effect |
|------|--------|
| `--watch [seconds]` | Re-read on an interval (default 60, **minimum 30** — the Claude endpoint is shared with the Claude Code CLI and rate-limits per account) |
| `--json` | Machine-readable output, for scripting and status bars |
| `--no-color` | Disable ANSI colour (`NO_COLOR` is honoured too) |

> `--no-quarantine` is required because the app is ad-hoc signed (not notarized with an Apple
> Developer ID); it tells Gatekeeper to trust the download.

### From source

```bash
git clone https://github.com/pierreprudh/token-usage-island.git
cd token-usage-island
./build.sh install   # builds, installs to /Applications, and links the `usage` command
usage island
```

On first launch, macOS asks to allow reading the *"Claude Code-credentials"* Keychain item —
choose **Always Allow**.

**Launch at login:** open the card and toggle **Open at login** in the footer — it registers
the app via `SMAppService`, no digging through System Settings.

> **Note:** the notch UI needs an Apple Silicon MacBook with a notch. The app still runs on
> any Mac (macOS 14+) and falls back to a floating card below the menu bar on other displays
> — it ships as a universal binary, so Intel Macs are covered too.

## Usage

| Action | Result |
|--------|--------|
| **Hover** the notch | Tab springs open, showing the lead tool's 5 h and weekly usage |
| **Click** | Expands into the full card and fetches fresh values |
| **Drag** a row | Reorders the tools; the top one drives the collapsed lip |
| **Move away** | Collapses back into the notch |
| 📌 **Pin** | Keeps the card open |
| ↻ **Refresh** | Re-fetches on demand |

## Privacy

Everything is read locally. The single outbound request is the Claude usage call to
`api.anthropic.com`, authenticated with the OAuth token that Claude Code already stores in
your Keychain. Nothing is sent anywhere else, and there is no telemetry.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon or Intel
- The Swift toolchain — `xcode-select --install` (to build from source)

## Development

### Project layout

```
Sources/
  Core/               Foundation only — no SwiftUI, no AppKit
    Models.swift        Metric, Tool, RGB, milestone events, formatting
    Platform.swift      the ONLY OS-specific file — paths, credentials, SQLite, subprocess
    Fetchers.swift      the three provider readers
    Store.swift         throttle, milestone queue, last-good fallback (needs Combine)
  App/                SwiftUI island — notch tab + Control-Center card
    Appearance.swift    RGB → Color bridge and the bundled logos
    IslandView.swift    the island itself
    main.swift          AppKit panel, notch geometry, positioning
  CLI/                `usage status` — the same readings, headless
Resources/          Provider logos (Claude, Codex, OpenCode)
build.sh            Compile + bundle into a versioned universal .app
.github/workflows/  release.yml — tag-triggered build + GitHub Release
```

**The layer split is enforced by the build, not by convention.** `usage status` is compiled
from `Core/Models`, `Core/Platform` and `Core/Fetchers` and nothing else — so if the fetch
layer ever picks up a UI dependency, that target stops compiling. `Core/Store.swift` is the
one piece still tied to Apple (Combine's `ObservableObject`); porting the readings to another
OS means reimplementing `Platform.swift` and leaving everything else alone.

### Testing across MacBooks

The notch is measured live, but you can simulate any model on one machine via env vars —
handy for checking the layout without the hardware:

```bash
# Named preset: air13 | mbp14 | air15 | mbp16
TUI_SIMULATE=air13 "build/Token Usage Island.app/Contents/MacOS/TokenUsageIsland"

# Or an explicit notch size in points
TUI_NOTCH_W=170 TUI_NOTCH_H=38 ".../TokenUsageIsland"

# Add TUI_PREVIEW=1 to open the lip + card at launch (for screenshots)
```

### Releasing

Releases are cut by pushing a semver tag; a macOS GitHub Actions runner builds the app, zips
it, and publishes a GitHub Release with the `.zip` and its SHA-256.

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow prints the cask `version`/`sha256` in its run summary. With a `TAP_TOKEN` repo
secret (a PAT with `contents:write` on [`pierreprudh/homebrew-tap`](https://github.com/pierreprudh/homebrew-tap)),
it also auto-bumps the cask so `brew upgrade` picks up the new build; otherwise paste those two
values into `Casks/token-usage-island.rb` by hand.

## Notes

- **Codex** reflects your most recent Codex session — its limits come from local logs, which
  only update when Codex talks to its server.
- The Claude usage endpoint is rate-limited; a transient failure keeps the last good reading
  instead of blanking, and shows `—` until data returns.

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The app is
intentionally dependency-free (SwiftUI + AppKit only); please keep it that way.

## License

[MIT](LICENSE)

---

<div align="center">
<sub>Built with Claude Code.</sub>
</div>
