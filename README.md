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

It's sized to Apple's real notch metrics (185 × 32 pt on the 14"/16" MacBook Pro) and adapts
automatically when moved to a display without a notch.

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

```bash
git clone https://github.com/pierreprudh/token-usage-island.git
cd token-usage-island
./build.sh
cp -R "build/Token Usage Island.app" /Applications/
open "/Applications/Token Usage Island.app"
```

On first launch macOS asks to allow reading the *"Claude Code-credentials"* Keychain item —
choose **Always Allow**.

**Launch at login:** System Settings → General → Login Items → **+** → *Token Usage Island*.

## Usage

| Action | Result |
|--------|--------|
| **Hover** the notch | Tab springs open, showing Claude's 5 h and weekly usage |
| **Click** | Expands into the full card and fetches fresh values |
| **Move away** | Collapses back into the notch |
| 📌 **Pin** | Keeps the card open |
| ↻ **Refresh** | Re-fetches on demand |

## Notes

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
build.sh            Compile + bundle into a .app
```

---

<div align="center">
<sub>Built with Claude Code.</sub>
</div>
