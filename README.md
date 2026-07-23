# Token Usage Island

A macOS notch HUD (Dynamic-Island style) that shows your AI-coding **plan-limit usage**
at a glance — so you don't have to open each app. Sized to the real notch (185×32 pt).

- **At rest:** invisible — a black tab flush with the notch.
- **Hover:** the tab springs open (overgrow) and reveals Claude's `12% 5h  29% 7d`.
- **Click:** expands into a light Control-Center card with all three tools.

![expanded](scratch/cc_expanded-crop.png)

## What it shows

| Tool | Source | Metric |
|------|--------|--------|
| **Claude** | live `GET /api/oauth/usage` (OAuth token read from Keychain) | Session (5h) % + Weekly %, with reset times — exactly what `/usage` shows |
| **Codex** | last `rate_limits` event in the newest `~/.codex/sessions/**/*.jsonl` | Weekly % + plan, as of your last Codex run |
| **OpenCode** | `~/.local/share/opencode/opencode.db` (SQLite, `json_extract`) | $ spent + tokens this week (pay-as-you-go — no plan limit exists) |

Nothing leaves your machine except the Claude usage call, which goes straight to
`api.anthropic.com` with your own Claude Code OAuth token.

## Usage

- **Hover** the notch → the tab springs open and shows both Claude rates.
- **Click** → expands into the light card and fetches fresh values.
- **Move away** → collapses. **📌 Pin** keeps it open. **↻** refreshes. **Quit** in the footer.
- No background polling — it fetches at launch and whenever you open it.

The first launch may prompt to allow reading the *"Claude Code-credentials"* Keychain
item — click **Always Allow**.

## Build

```bash
./build.sh                              # compiles + bundles build/Token Usage Island.app
cp -R "build/Token Usage Island.app" /Applications/
open "/Applications/Token Usage Island.app"
```

Requires the Swift toolchain (`xcode-select --install`), macOS 14+.

### Launch at login
System Settings → General → Login Items → **+** → add *Token Usage Island*.

## Layout

- `Sources/Data.swift` — models, the three fetchers, and the bundled logos.
- `Sources/IslandView.swift` — SwiftUI island (notch tab + light Control-Center card).
- `Sources/main.swift` — AppKit borderless panel, notch geometry + anchoring.
- `Resources/` — provider logos (Claude, Codex, OpenCode SVGs).
