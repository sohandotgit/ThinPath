# SwiftUI Wrapper — Test Spec

**Session:** S4 (SwiftUI wrapper test spec) · **Status: FROZEN** · **Blocked by:** S3 · **Blocks:** S5
**Input:** `Design/swiftui-wrapper-api.md` (the pinned API — treated as fixed)
**Output:** this file + `Tests/ThinPathTests/SwiftUIWrapperTests.swift` +
`Sources/ThinPath/SwiftUIWrapper.swift` (provisional compile-stub, fatalError bodies)

This spec is **FROZEN**. Session S5 (implementation) must make every case below pass by writing
real bodies in `Sources/ThinPath/SwiftUIWrapper.swift` — it must not edit the assertions in
`SwiftUIWrapperTests.swift` or the signatures in `SwiftUIWrapper.swift`. If S5 believes a case is
wrong, that is a design question routed back through S3, not something to quietly change.

---

## 1. What exists today (provisional, not the implementation)

`Sources/ThinPath/SwiftUIWrapper.swift` declares every public symbol from
`Design/swiftui-wrapper-api.md` §3–§4 verbatim (`ThinPathView`, `ThinPathRenderingMode`, the
`Image` extension) so this spec's tests compile against a stable shape before S5 exists — the same
convention `APISurface.swift` originally used to unblock `RenderTests.swift`. Every body is
`fatalError("... unimplemented ...")`. S5's job is to replace those bodies; the signatures are
already frozen by S3 and must not move.

One naming hazard documented in that file: ThinPath's own IR declares `Image` and `Text` structs
(`SVGModel.swift`, for the `<image>`/`<text>` SVG elements). Inside the `ThinPath` module, an
unqualified `extension Image { ... }` binds to the *sibling IR type*, not `SwiftUI.Image` — same-
module lookup wins over the imported module's type of the same name. The stub extends
`SwiftUI.Image` explicitly; the test file qualifies `SwiftUI.Image`/`SwiftUI.Text` at every use
site for the same reason. S5 must preserve the explicit qualification.

## 2. Two test classes, two purposes

`Tests/ThinPathTests/SwiftUIWrapperTests.swift`:

- **`SwiftUIWrapperConstructionTests`** — construction, composition, and default-parameter
  behavior. Never triggers an actual raster. **Passes today**, against the stub — it pins the API
  *shape* independent of rendering behavior existing yet.
- **`SwiftUIWrapperRenderingTests`** — anything needing an actual raster: snapshot parity,
  degenerate/error-handling output, scale/`preserveAspectRatio` fit, ideal size, threading-visible
  behavior. **Fails today**, against the stub, in one of two ways (both acceptable RED signals,
  neither needs crash-catching machinery):

  1. **`ThinPathView`-based cases fail via an ordinary assertion mismatch**, not a crash. The
     stub's `body` getter has only one reachable return expression (`EmptyView()`, after the
     `fatalError`), so the compiler infers `body`'s opaque `some View` underlying type as
     `EmptyView`. SwiftUI's runtime recognizes `EmptyView` statically and never calls the `body`
     getter at all for it — so the stub's `fatalError` never fires. The hosted snapshot is simply
     empty and differs pixel-for-pixel from the expected raster. (Two cases — the "malformed/no-
     root input renders transparent" ones — happen to **pass today**, because empty is also the
     *correct* final answer for those; this is a real, not accidental-in-a-bad-way, pass and it
     stays green once S5 lands.)
  2. **`Image`-based cases crash the process** (`fatalError` actually executes). The failable
     initializer and `Image.thinPath` are plain function calls, not a view body SwiftUI can elide
     around static type knowledge, so they hit the stub body directly. This is the same
     stub-crashes-the-suite convention `RenderTests.swift` already documents and accepts for
     `APISurface.swift`'s pre-implementation era.

Snapshot rendering (`HostingSnapshot` in the test file) hosts a view/`Image` in a real, offscreen
`NSHostingView` inside an invisible `NSWindow` (macOS is the native `swift test` host for this
package) and rasterizes its backing layer into a `CGContext` sized to an explicit pixel size
(`points × scale`), independent of the actual screen's backing scale factor. That helper is
test-only glue, not part of the frozen assertions below — S5 may adjust its mechanics if it doesn't
host some case correctly, as long as it doesn't weaken what a case actually asserts.

## 3. Checklist coverage (design doc §8, each row → concrete test)

| # | Design doc §8 item | Test(s) | Class |
|---|---|---|---|
| 1 | Availability under `canImport(SwiftUI)` | the file's mere existence/compilation | both |
| 2 | Construction: default-placeholder infers `Color`; custom-placeholder init compiles; defaults (`nil`/`nil`/`.asynchronous`) | `testDefaultPlaceholderInitInfersColor`, `testCustomPlaceholderInitCompiles`, `testConstructorDefaultsAreNilNilAsynchronous`, `testImageInitializerSignaturesCompile` | Construction |
| 3 | PAR default vs. override | `testConstructorDefaultsAreNilNilAsynchronous`, `testExplicitOverridesAreStoredVerbatim` (storage); `testNilPreserveAspectRatioUsesDocumentDefault`, `testNonNilPreserveAspectRatioOverridesDocumentDefaultForThisViewOnly` (rendered effect + IR-untouched check) | both |
| 4 | Scale default vs. override | `testConstructorDefaultsAreNilNilAsynchronous`, `testExplicitOverridesAreStoredVerbatim` (storage); `testNilScaleReadsEnvironmentDisplayScale`, `testNonNilScalePinsRasterIndependentOfEnvironment` (rendered effect) | both |
| 5 | Ideal size = `rootViewBox` size, else `.zero` | `testIdealSizeMatchesRootViewBoxWhenPresent`, `testIdealSizeIsZeroWhenNoRootViewBox` | Rendering |
| 6 | Flex/fit: resolved frame is the raster rect, PAR governs fit | `testNilPreserveAspectRatioUsesDocumentDefault`, `testNonNilPreserveAspectRatioOverridesDocumentDefaultForThisViewOnly` (non-square frame vs. square viewBox) | Rendering |
| 7 | Empty/degenerate → placeholder, no throw/trap | `testCompletelyInvalidSVGRendersEmptyWithoutThrowingOrTrapping`, `testNoRootViewBoxRendersEmptyPlaceholder` | Rendering |
| 8 | Caching: unchanged key → no re-rasterize; changed key → exactly one re-rasterize | **Not automated as a call-count assertion** — see §4 | — |
| 9 | Threading — `.synchronous`: main-thread, in-pass, placeholder never shown | `testSynchronousModeNeverShowsPlaceholderEvenWithNonClearPlaceholder` (observable proxy: a conspicuous placeholder never appears in the output) | Rendering |
| 10 | Threading — `.asynchronous`: off-main raster, main-actor publish, no-flash, single-flight/cancellation | `testAsynchronousSnapshotSettlesToSamePixelsAsDirectRenderPath`, `testAsynchronousModeEventuallyReplacesPlaceholderWithRasterMatchingDirectPath` (observable proxy: settles to correct pixels). No-flash/single-flight/cancellation internals are **not automated** — see §4 | Rendering |
| 11 | `Image(doc, size:scale:)`: non-nil for valid input, `nil` for degenerate, decorative | `testFixedSizeImageInitMatchesDirectRenderPath`, `testFixedSizeImageInitReturnsNilForDegenerateSizeOrScale` | Rendering |
| 12 | `Image.thinPath(...)` matches sync init, off-thread | `testAsyncImageProducerMatchesSyncInitForSameInputs` | Rendering |
| 13 | Snapshot parity vs. `ThinPath().render(_:size:scale:)` | `testSynchronousSnapshotMatchesDirectRenderPath`, `testAsynchronousSnapshotSettlesToSamePixelsAsDirectRenderPath`, `testFixedSizeImageInitMatchesDirectRenderPath` | Rendering |

Additional coverage beyond the checklist, following directly from the design doc's prose:

- **Composition** (§"it compiles and composes inside a SwiftUI hierarchy" in the S4 prompt):
  `testComposesInsideAStandardSwiftUIHierarchy` embeds `ThinPathView` in `VStack`/`HStack`, under
  `.frame(...)`, with a `preserveAspectRatio:` override, with a custom placeholder, and with
  `.accessibilityLabel(_:)` attached — all compile-checked together as one hierarchy.
- **Error handling for malformed SVG** (the S4 prompt's explicit ask): two malformed-input fixtures
  — completely-invalid data (§7 empty case) and a recoverable-but-erroring partial parse (renders
  its partial content, does not go empty just because `errors` is non-empty) — both exercised via
  `parse(data:)` directly, confirming the wrapper's contract that it never sees `[SVGParseError]`
  (§6).
- **IR immutability**: `testNonNilPreserveAspectRatioOverridesDocumentDefaultForThisViewOnly` also
  asserts the original document's `rootPreserveAspectRatio` is untouched after constructing a view
  with an override — the override is view-local render configuration, never an IR mutation (§1,
  §3.1).

## 4. Explicitly NOT automated here (and why)

- **Exact re-rasterization call counts** (§5.3 caching contract) and **single-flight/cancellation/
  no-flash guarantees** (§5.1): these are implementation-internal — no queue/executor identity, no
  cache-hit counter, is public API (by design, §3.1/§7, to keep the surface minimal). Asserting them
  black-box would require either a DEBUG-only instrumentation hook (a call counter, a
  cancellation-observed flag) that does not exist yet, or a flaky timing-based integration test.
  Both are out of scope for a frozen *public-API* test spec. If S5 (or a later session) wants
  stronger automated coverage here, it should add a `#if DEBUG` test hook to
  `Sources/ThinPath/SwiftUIWrapper.swift` and a corresponding **new, separate** test file — not an
  edit to the frozen assertions in this one.
- **tvOS**: not a declared package platform (§2); no test target runs there.

## 5. Fixtures used

- `SampleSVGs/shapes/flat_rect.svg` (via `SnapshotSupport.loadSampleSVG`): 100×100 viewBox, a red
  40×40 rect on white — the same fixture `RenderTests.swift` uses for exact spot-pixel checks, reused
  here so wrapper-vs-direct-path comparisons have a known, non-trivial pixel pattern.
- Two inline fixtures in `SwiftUIWrapperTests.swift` (`Fixture.completelyInvalidData`,
  `Fixture.malformedButPartiallyRecoverableData`), mirroring the malformed-input cases already
  frozen in `ParsingTests.swift` (`testCompletelyInvalidDataDoesNotCrashAndReportsErrors`,
  `testMalformedXMLYieldsPartialTreeAndNonEmptyErrors`).

## 6. Done criteria (met at freeze time)

- [x] `swift build` succeeds (the provisional stub compiles under `canImport(SwiftUI)`).
- [x] `swift build --build-tests` succeeds (the frozen spec compiles against the stub).
- [x] `SwiftUIWrapperConstructionTests` passes today (API shape is already correct).
- [x] `SwiftUIWrapperRenderingTests` fails today, either by assertion mismatch or by the documented
      stub crash — never by an unrelated/accidental error (verified case-by-case at freeze time).
- [ ] `SwiftUIWrapperRenderingTests` passes green with `Sources/ThinPath/SwiftUIWrapper.swift`'s
      real implementation — S5's job, not this session's.
