<div align="center">

# Token Usage Island

**Your AI-coding plan limits, live in the notch.**

A native macOS notch HUD that shows how much of your **Claude**, **Codex**, and **OpenCode**
usage you've burned — without opening a single app.

![Token Usage Island — hover state](docs/hover.png)

![Platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift&logoColor=white)
![Menu bar](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-blue)

</div>

---

## Overview

Token Usage Island lives in the MacBook notch. At rest it's invisible — a black tab flush
with the notch. **Hover** it and the tab springs open to reveal your Claude session and
weekly usage; **click** it and it expands into a light, Control-Center-style card with a
full breakdown for all three tools.

It sizes itself to **your Mac's actual notch** — read live from the display at launch
(`safeAreaInsets` + the menu-bar auxiliary areas), so it fits the 14"/16" MacBook Pro and the
13"/15" MacBook Air alike, and re-measures if you change display scaling or move it to a
screen without a notch (where it falls back to a floating card).

## Features

- **Glanceable** — hover reveals both Claude rates (`25% 5h · 29% 7d`), colour-coded by severity.
- **Three tools, one place** — Claude, Codex, and OpenCode side by side.
- **Native & lightweight** — SwiftUI + AppKit, a single borderless panel, no dependencies.
- **Private by design** — reads local files and your own Keychain token; the only network
  call goes straight to Anthropic with your own credentials.
- **On-demand** — no background polling; it fetches at launch and whenever you open it.
- **Fluid** — an Apple-style spring reveal with a subtle overgrow.

## What it shows

| Tool | Source | Metric |
|------|--------|--------|
| **Claude** | Live `GET /api/oauth/usage` (OAuth token from the Keychain) | Session (5 h) % + Weekly %, with reset times — the same data as `/usage` |
| **Codex** | Latest `rate_limits` event in `~/.codex/sessions/**/*.jsonl` | Weekly % + plan, as of your last Codex run |
| **OpenCode** | `~/.local/share/opencode/opencode.db` (SQLite) | Spend + tokens this week — pay-as-you-go, so no plan cap |

## Privacy

Everything is read locally. The single outbound request is the Claude usage call to
`api.anthropic.com`, authenticated with the OAuth token that Claude Code already stores in
your Keychain. Nothing is sent anywhere else, and there is no telemetry.

## Requirements

- macOS 14 (Sonoma) or later
- The Swift toolchain — `xcode-select --install`

## Install

### Homebrew (recommended)

```bash
brew install --cask --no-quarantine pierreprudh/tap/token-usage-island
usage island   # launch from anywhere
```

The cask puts a `usage` command on your `PATH`, so you can control the app from any terminal
(with `<TAB>` completion in zsh):

```bash
usage island     # launch the app
usage off        # turn it off       (aliases: quit, stop)
usage restart    # relaunch it
usage version    # print the installed version
usage help       # show all commands
```

`--no-quarantine` is required because the app is ad-hoc signed (not notarized with an Apple
Developer ID); it tells Gatekeeper to trust the download.

### From source

```bash
git clone https://github.com/pierreprudh/token-usage-island.git
cd token-usage-island
./build.sh install   # builds, installs to /Applications, and links the `usage` command
usage island
```

On first launch macOS asks to allow reading the *"Claude Code-credentials"* Keychain item —
choose **Always Allow**.

> **Note:** the notch UI requires an Apple Silicon MacBook Pro; the app runs on any Mac
> (macOS 14+) but falls back to a floating card on displays without a notch.

**Launch at login:** open the card and toggle **Open at login** in the footer. (No need to
dig through System Settings — it registers the app via `SMAppService`.)

## Usage

| Action | Result |
|--------|--------|
| **Hover** the notch | Tab springs open, showing Claude's 5 h and weekly usage |
| **Click** | Expands into the full card and fetches fresh values |
| **Move away** | Collapses back into the notch |
| 📌 **Pin** | Keeps the card open |
| ↻ **Refresh** | Re-fetches on demand |

## Notes

- **24h trend** — each metric shows a small sparkline of the last 24 hours under its bar,
  so you can see whether you're climbing toward the cap. Readings are stored in
  `~/Library/Application Support/Token Usage Island/history.json` and appear once there are
  at least two data points.
- **Codex** reflects your most recent Codex session — its limits are read from local logs,
  which only update when Codex talks to its server.
- The Claude usage endpoint is rate-limited; a transient failure keeps the last good reading
  instead of blanking, and shows `—` until data returns.

## Project layout

```
Sources/
  Data.swift        Models, the three usage fetchers, bundled logos
  IslandView.swift  SwiftUI island — notch tab + light Control-Center card
  main.swift        AppKit panel, notch geometry, positioning
Resources/          Provider logos (Claude, Codex, OpenCode)
build.sh            Compile + bundle into a versioned .app
.github/workflows/  release.yml — tag-triggered build + GitHub Release
```

## Testing across MacBooks

The notch is measured live, but you can simulate any model on one machine via env vars
(handy for checking the layout without the hardware):

```bash
# Named preset: air13 | mbp14 | air15 | mbp16
TUI_SIMULATE=air13 "build/Token Usage Island.app/Contents/MacOS/TokenUsageIsland"

# Or an explicit notch size in points
TUI_NOTCH_W=170 TUI_NOTCH_H=38 ".../TokenUsageIsland"

# Add TUI_PREVIEW=1 to open the lip + card at launch (for screenshots)
```

## Releasing

Releases are cut by pushing a semver tag; a macOS GitHub Actions runner builds the app,
zips it, and publishes a GitHub Release with the `.zip` and its SHA-256.

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow prints the cask `version`/`sha256` in its run summary. If a `TAP_TOKEN` repo
secret (a PAT with `contents:write` on [`pierreprudh/homebrew-tap`](https://github.com/pierreprudh/homebrew-tap))
is set, it also auto-bumps the cask so `brew upgrade` picks up the new build; otherwise paste
those two values into `Casks/token-usage-island.rb` in the tap by hand.

---

<div align="center">
<sub>Built with Claude Code.</sub>
</div>
