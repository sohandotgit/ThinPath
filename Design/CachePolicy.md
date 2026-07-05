# CachePolicy.md — Decoded-image cache & eviction

Companion to `Sources/ThinPath/ImageCache.swift`. Defines the eviction policy
for the decoded-`<image>` cache. The policy is stated here, but the whole
subsystem is flagged:

> ⚠️ **STRESS-TEST UNDER PROFILING (Session 7).** Eviction under real memory
> pressure is the thing in this subsystem most likely to be wrong. Every number
> and every behaviour below is a hypothesis to validate on-device with Instruments,
> not a settled fact.

---

## 1. What this cache is for

`<image>` in the IR is only an href (SVGModel.swift); decoding is deferred to render
time at the **target scale** so we never pin full-resolution bitmaps for the
document's lifetime (a core project constraint). This cache sits at that boundary:
it holds a **bounded budget** of already-decoded `CGImage`s so repeated draws (tiles,
scroll, re-invalidation, a `<use>`/pattern that repeats an image) don't re-decode.

It caches **decoded output**, keyed by **target size**, not source bytes.

---

## 2. Key: (href, target pixel size)

```swift
struct Key { href: StringRef; pixelWidth: Int; pixelHeight: Int }
```

The **same source at two target sizes is two entries** — a 64×64 thumbnail and a
1024×1024 full tile are genuinely different decodes, and conflating them would
either over-blur or waste memory. The href is the interned `StringRef` from the
owning document.

**STRESS-TEST (key-granularity):** exact pixel size as key can fragment the cache if
a resize animation walks through many sizes. Consider **bucketing** sizes (round up
to a size class) so near-identical requests share an entry. Measure whether
fragmentation is real before adding buckets.

---

## 3. Cost model & budget

- **Cost = decoded bytes = `width × height × 4`** (8-bit RGBA/BGRA, matching the
  surfaces we request). This is the honest resident cost, unlike source-byte size
  (a 2 KB SVG-referenced PNG can decode to 16 MB).
- **Budget = a fixed byte ceiling** (`budgetBytes`), a fraction of the app's memory
  limit. The default in code is a placeholder.
- **Per-entry cap:** an image larger than `budgetBytes × maxSingleEntryFraction`
  (default 0.5) is **used but not admitted** — one oversized image must not evict the
  entire working set only to be evicted itself on the next insert (classic cache
  thrash). It is decoded, returned, and dropped.

**STRESS-TEST (budget / fraction):** the budget number, `maxSingleEntryFraction`,
and whether cost should also count colour-space/alpha overhead are all Session-7
outputs. Wide-gamut/16-bit decode **doubles** cost — see MemoryModel colour-depth
PROFILE-CHECK.

---

## 4. Eviction: LRU by cost

- Structure: `[Key: Node]` for O(1) lookup + an intrusive **doubly-linked list**
  (MRU head, LRU tail) for O(1) promote / evict. Chosen over `NSCache` **on purpose**:
  `NSCache` eviction is opaque and non-deterministic, i.e. exactly the property we
  cannot profile. We want an explicit, observable, testable order.
- `image(for:decode:)` — get-or-decode. Hit → promote to MRU. Miss → decode via the
  caller's closure (the cache owns no image-format/colour-space policy), admit
  (unless oversized), then `evictToBudget()`.
- `evictToBudget()` — after every admission, evict from the LRU tail until
  `currentCostBytes ≤ budgetBytes`.

**STRESS-TEST (in-pass eviction):** the single most likely bug. Under a **tiled**
render one pass may touch many tiles of one huge image; naive LRU could evict a tile
still needed **later in the same pass**, causing re-decode thrash. If profiling shows
this, the fix is a **per-pass pin set** (tiles referenced this pass are un-evictable
until the pass ends), **not** a bigger budget. The interface leaves room for a pin
set without an API change.

---

## 5. Memory pressure

`handleMemoryPressure(_:)` — the host wires this to a `DispatchSource` memory-pressure
event (or a UIKit memory warning); the cache stays **UIKit-free** so the library has
no app-framework dependency.

- `.warning` → evict to a **reduced** budget (default: halve), keeping hot entries.
- `.critical` → **purge all**.

**STRESS-TEST (pressure-policy):** whether `.warning` should halve, quarter, or use a
cost-decay curve, and whether purge-all on `.critical` is too aggressive (re-decode
storm right after), are the core Session-7 questions. Also validate the notification
actually fires early enough on-device to prevent a jetsam kill — a cache that evicts
*after* the OS has already decided to kill us is useless.

---

## 6. Session-7 stress-test checklist

1. **Budget number** vs app memory limit and typical document image payload.
2. **`maxSingleEntryFraction`** vs real oversized-image behaviour (thrash?).
3. **In-pass eviction** under tiled render — add a per-pass pin set if tiles thrash.
4. **Key granularity** — bucket sizes if resize animations fragment the cache.
5. **Pressure policy** — `.warning` reduction curve; `.critical` purge vs partial;
   notification timing vs jetsam.
6. **Cost accuracy** — confirm `w×h×4` matches actual resident bytes for the surface
   formats/colour spaces we decode to; adjust for 16-bit/wide-gamut.
7. **Concurrency** — if decode/render moves off the main thread, the cache needs a
   lock or actor isolation; decide and test before Session 7 signs off.
