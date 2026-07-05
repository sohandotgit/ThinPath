# ImageDecodeNotes.md — the `<image>` decode path

Companion to `Sources/ThinPath/ImageDecoder.swift`. Also read
`CachePolicy.md` (the cache this feeds) — the two documents split the boundary:
CachePolicy owns *retention*, this document owns *how pixels come to exist*.

**THE RULE.** The only call in the codebase that may materialize image pixels is
`CGImageSourceCreateThumbnailAtIndex`, always with an explicit
`kCGImageSourceThumbnailMaxPixelSize`. `CGImageSourceCreateImageAtIndex` (and
any `UIImage`/`NSImage`-mediated decode) is banned: it decodes at native
resolution, and one native decode of a 12 MP photo is ~48 MB — larger than any
plausible budget for this whole subsystem. There is no "decode full, then
downscale" step anywhere, even as an intermediate.

---

## 1. Shape of the path

```
href (StringRef, from the IR)
  └─ cache lookup, key = (href, ceil(target px size)) ──── hit ──► CGImage (no work)
       └─ miss: parse href
            ├─ data: URI → base64 → compressed bytes → CGImageSourceCreateWithData
            └─ external  → local file URL            → CGImageSourceCreateWithURL
                 └─ header-only probe: native dimensions + EXIF orientation
                      └─ CGImageSourceCreateThumbnailAtIndex(maxPixelSize) ──► CGImage
                           └─ admitted to ImageCache (cost = actual w × h × 4)
```

Everything below the "miss" line runs inside the `ImageCache.image(for:decode:)`
closure. A hit is one dictionary lookup + LRU promote: **no href parsing, no
base64 decode, no allocation**. This is what "decode data-URI bytes lazily"
means concretely — the encoded payload is not touched unless this exact
(href, size) is absent from the cache.

Failure at any stage returns `nil` and the element renders as nothing (SVG's
broken-image behaviour). No `throw`, no trap: a malformed base64 blob, a missing
file, or a corrupt PNG in a hostile document must never crash the renderer.

---

## 2. Why each ImageIO option is set

### At source creation — `kCGImageSourceShouldCache: false`
ImageIO keeps its own per-source cache of decoded frames. We own retention in
`ImageCache` — deterministic, budgeted, profileable (the same reason
CachePolicy.md rejects NSCache). Letting ImageIO cache *too* would hold a second
decoded copy of every image, invisibly, outside our budget. The source object
itself is scoped to a single decode call, so this option is belt-and-braces —
but it also suppresses caching during the header probe.

### `kCGImageSourceCreateThumbnailFromImageAlways: true`
Without it, ImageIO prefers an *embedded* thumbnail (EXIF/JFIF preview) when one
exists. Embedded thumbnails have arbitrary author-controlled size (typically
160×120) and quality, so the result could be either uselessly blurry or —
worse for the memory story — absent, silently falling back to behaviour we
didn't choose. With `FromImageAlways`, `maxPixelSize` is the single
authoritative size contract, and ImageIO generates from the primary image data
using its subsampled/progressive decode machinery.

### `kCGImageSourceShouldCacheImmediately: true`
Forces the decode to happen *inside* the `CreateThumbnailAtIndex` call, into the
returned image's own buffer. Without it the returned `CGImage` can be lazy,
decoding at first draw. Lazy decode is wrong here twice over:

1. **Cost accounting.** The cache computes cost from the image at admission
   time. A lazy image would be admitted at full cost while its bytes don't
   exist yet, then materialize them later — `currentCostBytes` would be a
   fiction and the Session-7 profiling of the budget meaningless.
2. **Predictability.** Decode-at-first-draw moves the CPU hit onto whichever
   draw call happens to touch the image first (mid-scroll, mid-animation), and
   keeps the compressed source data alive until then. We want decode cost to
   appear exactly at the cache-miss site, where it is measurable and, later,
   movable to a background stage.

### `kCGImageSourceCreateThumbnailWithTransform: true`
Bakes EXIF orientation into the pixels. Without it, a rotated photo returns a
buffer in *sensor* orientation and the renderer would need to know to rotate at
draw time (it doesn't). With it, `image.width/height` equal what is drawn, which
also keeps `ImageCache.decodedCost` and the size-derived cache key consistent
with reality. The decoder correspondingly compares the target against
*post-transform* native dimensions (orientations 5–8 swap width/height).

### `kCGImageSourceThumbnailMaxPixelSize: N`
The clamp itself — see §3 for exactly how `N` is derived. This is what lets
ImageIO decode subsampled (e.g. JPEG DCT scaled decode at 1/2, 1/4, 1/8) instead
of materializing the native-resolution bitmap.

---

## 3. Target draw size → `maxPixelSize`, exactly

Definitions:

- **Target size** `(tW, tH)`: the device-pixel size of the `<image>` element's
  destination rect under the current CTM — `RenderContext.targetPixelSize(for:)`
  applies the element rect through `userToDevice`, which already composes every
  ancestor transform with the screen scale. There is no separate `× scale`
  step; zoom and scale are inside the CTM by construction.
- **Native size** `(nW, nH)`: the source's pixel dimensions, read from
  `CGImageSourceCopyPropertiesAtIndex` — a **header-only** read that decodes no
  pixels — with width/height swapped for EXIF orientations 5–8.

`kCGImageSourceThumbnailMaxPixelSize` bounds the **longer** side of the output,
preserving aspect ratio. The smallest decode covering the target on **both**
axes is:

```
scale        = max(tW / nW, tH / nH)      // per-axis need; take the binding axis
maxPixelSize = ceil(max(nW, nH) × min(scale, 1))
```

Properties of this formula:

- **Sufficient**: `max(...)` of the per-axis ratios picks the axis that needs
  the most resolution, so after ImageIO's aspect-preserving scale both axes are
  ≥ target. Using `max(tW, tH)` naively instead would under-decode one axis
  whenever the element stretches the image (`preserveAspectRatio="none"` with a
  mismatched aspect ratio).
- **Minimal**: `ceil` is the only slack; the decode is never a full size class
  larger than needed.
- **Never upscales**: `min(scale, 1)` clamps at native. When the target exceeds
  the source, we decode native-size and let Core Graphics interpolate up at
  draw time. Decoding "bigger than the source" costs real memory for zero
  information.
- **Degrades safely**: if the header is unreadable, fall back to
  `max(tW, tH)` — still bounded by the target's longer axis, never unbounded.

Known conservatisms (deliberate, both err toward sharp-not-bloated by a bounded
factor):

- **Rotation/skew in the CTM**: the target is the transformed rect's
  axis-aligned bounding box, an over-estimate for rotated images (worst case
  ~√2 per axis at 45°), and always native-clamped.
- **`preserveAspectRatio` meet**: the image may be letterboxed inside its
  element rect, so the drawn image is smaller than the rect we sized against.
  Refining this means resolving the pAR mapping before decode; do it only if
  profiling shows it matters.

## 3a. Cache interaction

- **Key = ceil'd *requested* target size**, not the native-clamped decode size.
  Reason: computing the clamp needs the source header, and for a `data:` URI
  that means a base64 decode — on *every* lookup, including hits. The key must
  be derivable from the request alone so the hit path stays free.
- Consequence: two different super-native target sizes create two entries with
  identical native-res pixels. Bounded (each costs only native-size bytes) and
  self-correcting via LRU; if profiling shows it matters it folds into the
  key-bucketing question CachePolicy.md §2 already tracks.
- **Cost is honest regardless of key**: `ImageCache.decodedCost` reads the
  *actual decoded* image's dimensions, so a native-clamped decode is charged at
  its real (smaller) size, not the requested one.

## 3b. Derived buffers after decode — the visible-region bound

The decoder's native clamp (§3) bounds what *decode* can allocate, but
`ImageRenderer` derives one more pixel buffer after decode: the exact-size
bilinear resample of the decoded image to its device fit rect (for
deterministic cross-renderer magnification). That buffer is sized from
`fitRectDevice` — the element rect through the full CTM — and the CTM composes
*every* ancestor space, including pattern and `<use>` spaces. Nothing upstream
guarantees it is sane.

**THE BOUND.** A derived buffer may only be materialized when its device rect
lies inside the region the pass can actually produce — `clip ∩ dirty`, ±1 px
rounding slack (`ImageRenderer.fitsVisibleDeviceBounds`). Past that bound, the
decoded (already native-clamped) image is drawn directly and Core Graphics
samples it through the clip at draw time: bounded by the render target no
matter what the CTM claims. Degenerate rects (null/infinite/NaN from a broken
CTM) fail the containment test, i.e. fail *safe*.

This bound was added after a real incident (Compositing.md §4a): a
wrong-space pattern content matrix inflated `fitRectDevice` to
~178,800 × 80,000 px on a 592×400 render, and the resampler tried to
materialize ~57 GB. The decode path itself held (native clamp → 1192×800);
the derived buffer was the hole. Note the decode *request* is deliberately
NOT clamped to the visible region: a partially-visible image still needs
scale-derived resolution for the part that shows, and the native clamp
already bounds the decode. Regression-tested end-to-end in
`PatternImageMemoryTests` (footprint bound + every cache-key request
device-sized).

---

## 4. Buffer lifecycle for `data:` URIs

The encoded base64 text lives permanently in the document's string pool (it *is*
the href — an IR/parser fact, not this file's to change). What this file
controls is every buffer *derived* from it:

| Buffer | Created | Released |
|---|---|---|
| UTF-8 copy of base64 substring | miss path, payload extraction | end of `dataURIPayload` (same call) |
| Compressed image bytes (PNG/JPEG) | `Data(base64Encoded:)` | with the `CGImageSource`, end of `decode(...)` |
| Decoded pixels (the thumbnail) | `CreateThumbnailAtIndex` | owned by the cache / caller |

So: the encoded-bytes copy exists only for the duration of one function call;
the compressed bytes exist only for the duration of one decode; the returned
`CGImage` retains **neither** (it owns only its own pixel buffer). Peak
transient overhead on the miss path is `encoded + compressed` for the base64
window, then `compressed + decoded` during the thumbnail call — never
`encoded + compressed + full-res-decoded`.

`.ignoreUnknownCharacters` is passed to the base64 decode because
pretty-printed SVG wraps base64 payloads with newlines/whitespace; a strict
decode would reject real-world files.

## 4a. External sources

`CGImageSourceCreateWithURL` — never `Data(contentsOf:)` + `CreateWithData`.
ImageIO opens/maps the file itself and reads what the header probe and the
subsampled decode actually need; slurping the file first would put the whole
compressed payload on our heap even when decoding a tiny thumbnail from a huge
file. Network schemes are refused (`nil`): this is the synchronous render path;
remote images belong to a future async prefetch that lands files locally first.

---

## 5. PROFILE-CHECK items

Same contract as MemoryModel.md / CachePolicy.md: hypotheses to validate with
Instruments on device, not settled facts.

1. **PROFILE-CHECK (no-full-res-transient)** — the headline check. In
   Allocations/VM Tracker, decode a large JPEG *and* a large PNG to a small
   target and confirm no transient allocation at native decoded size
   (`nW × nH × 4`) appears — watch `ImageIO_*` and CG raster VM regions, not
   just malloc. JPEG has true scaled decode (DCT downscale); **PNG has no
   in-codec subsampling**, so ImageIO may stream full-width rows — row-buffer
   transients are fine, a full-frame transient is a failure of this design and
   would force a format-specific strategy.
2. **PROFILE-CHECK (zoom-bounded-by-cache)** — drive a zoom-in/zoom-out cycle
   over an `<image>` and confirm (a) decode count per (href, size) is ≤ 1 while
   within budget, i.e. returning to a previous zoom level is a pure cache hit;
   (b) a pinch *animation* doesn't fragment the cache with dozens of
   one-frame-lived sizes — if it does, that is CachePolicy §2's bucketing
   question, solved there (size classes), not by decoding differently.
3. **PROFILE-CHECK (thumbnail-bpp)** — `ImageCache.decodedCost` assumes 4
   bytes/pixel. Confirm `CreateThumbnailAtIndex` returns 32 bpp surfaces for
   our corpus; a 16-bit or wide-gamut source producing a 64 bpp thumbnail would
   make the cache under-charge by 2× — exactly CachePolicy §3's colour-depth
   caveat. If it happens, fix the *cost model*, don't fight the surface format
   here.
4. **PROFILE-CHECK (native-clamp-holds)** — request a target far larger than a
   small source and confirm the decoded image is native-size (no upscaled
   buffer) and the EXIF-orientation swap yields correctly-sized results for
   orientations 5–8 (a transposed portrait photo is the classic off-by-swap).
   *Confirmed in the field* (2026-07 pattern incident): a 176,417 × 80,000 px
   request against a 1192×800 PNG decoded exactly 1192×800. The clamp held;
   the blow-up was downstream (§3b).
5. **PROFILE-CHECK (imageio-cache-off)** — repeat-decode the same source and
   confirm ImageIO's internal caches don't grow (i.e. `ShouldCache: false` at
   source creation is actually honored across OS versions); otherwise every
   image is resident twice, once in our budget and once outside it.
6. **PROFILE-CHECK (decode-on-render-thread)** — `ShouldCacheImmediately`
   deliberately pays the decode inside the miss, which is on the render thread.
   Measure worst-case miss latency against the frame budget with a
   many-first-time-images document; if it stalls, the fix is moving the miss
   *off-thread* (async decode + placeholder), keeping this decoder unchanged —
   which also triggers CachePolicy §6.7 (cache concurrency).
7. **PROFILE-CHECK (data-uri-transient-window)** — for the largest embedded
   data: URI in the corpus, confirm the `encoded + compressed` coexistence
   window (§4) is short-lived and its peak is small relative to the decoded
   output; if pretty-printed multi-MB base64 payloads make it matter, a
   streaming base64 decode is the escape hatch.
