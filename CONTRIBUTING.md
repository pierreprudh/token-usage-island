# Contributing

Thanks for your interest in Token Usage Island.

## Workflow

`main` is protected — only the maintainer pushes to it directly. Everyone else contributes
via pull request:

1. **Fork** the repository.
2. Create a branch: `git checkout -b my-change`.
3. Make your change and build it (see below).
4. Open a **pull request** against `main`.

Direct pushes to `main` from non-maintainers are rejected by branch protection, so please
don't be surprised — open a PR instead.

## Building

Requires macOS 14+ and the Swift toolchain (`xcode-select --install`).

```bash
./build.sh
open "build/Token Usage Island.app"
```

## Testing across MacBooks

The notch is measured live, but you can simulate any model without the hardware:

```bash
TUI_SIMULATE=air13 "build/Token Usage Island.app/Contents/MacOS/TokenUsageIsland"
# presets: air13 | mbp14 | air15 | mbp16   (or TUI_NOTCH_W=<pt> TUI_NOTCH_H=<pt>)
# add TUI_PREVIEW=1 to open the lip + card for screenshots
```

## Guidelines

- Keep pull requests focused and match the surrounding code style.
- The app is intentionally dependency-free (SwiftUI + AppKit only) — please keep it that way.
- Everything runs locally; don't add telemetry or network calls beyond the documented usage
  endpoints.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
