# Contributing to ThinPath

Thanks for your interest in improving ThinPath. This document covers how to
report issues, propose changes, and get a pull request merged.

## Ways to Contribute

- **Report a bug.** Open an issue with a minimal SVG that reproduces it and the
  output you expected versus what you got. Attach the SVG file itself where you
  can — a screenshot alone rarely pins down a rendering bug.
- **Request a feature.** Check the "Not yet supported" list in the README first
  (SMIL/CSS animation, filters, scripting, embedded fonts). If it's on that
  list, an issue tracking demand is welcome; if it's something new, describe the
  SVG use case it unblocks.
- **Submit a fix or feature.** See the workflow below.

For anything substantial — new element support, IR changes, a new render pass —
please open an issue to discuss the approach before you write the code. It saves
everyone a round trip.

## Development Setup

ThinPath is a plain Swift package with no runtime dependencies.

```sh
git clone https://github.com/sohandotgit/ThinPath.git
cd ThinPath
swift build
swift test
```

Requires Swift 5.9+ and a deployment target of iOS 13+, macOS 11+, or watchOS 7+ (see `Package.swift`).

## Project Layout

- `Sources/ThinPath/` — the library. Parsing (`SVGParser`, `PathDataParser`),
  the IR (`SVGModel`), style resolution (`StyleResolver`, `ReferenceResolver`),
  and the render passes (`ShapeRenderer`, `GradientRenderer`, `PatternRenderer`,
  `ClipRenderer`, `MaskRenderer`, `TextRenderer`, `ImageRenderer`, …). The
  public entry points live in `APISurface.swift` and `ThinPath.swift`.
- `Tests/ThinPathTests/` — unit and rendering tests.
- `Design/` — architecture and rationale docs. Read `MemoryModel.md`,
  `RenderPipeline.md`, and `CascadeRules.md` before changing the IR or the
  render walk.
- `Examples/` — runnable usage snippets.

## Testing

Run the full suite with `swift test`. Rendering correctness has two tiers in
`RenderTests.swift`:

- **EXACT** — hand-computed spot-pixel assertions, self-contained. Prefer this
  tier for anything simple enough to compute by hand.
- **GOLDEN** — comparisons against reference PNGs in
  `Tests/ThinPathTests/SampleSVGs/references/`, generated from an independent
  renderer. If you add a golden case, follow `Design/GoldenWorkflow.md`: the
  reference must come from an outside oracle (headless browser, `rsvg-convert`,
  or `resvg`), never from ThinPath itself.

Please add or update tests for any behavior change, and make sure the suite is
green before opening a PR.

## Pull Requests

1. Fork the repo and create a topic branch off `main`.
2. Keep changes focused — one logical change per PR.
3. Match the style of the surrounding code; keep the memory-first IR invariants
   intact (no per-node heap allocation, indices valid only against their owning
   document).
4. Update `Design/` docs and the README when you change public API or behavior.
5. Ensure `swift build` and `swift test` pass.
6. Write a clear PR description: what changed, why, and how you verified it.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE) that covers this project.
