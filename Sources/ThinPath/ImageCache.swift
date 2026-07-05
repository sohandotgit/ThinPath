//
//  ImageCache.swift
//  ThinPath
//
//  A decoded-image cache for `<image>` elements. The project constraint is that
//  we NEVER pin full-resolution bitmaps for the document's lifetime: `<image>` in
//  the IR is just an href (SVGModel.swift), and decoding is deferred to render
//  time at the *target* scale. This cache sits at that boundary — it holds a
//  bounded budget of already-decoded `CGImage`s keyed by (href, target pixel
//  size) so repeated tiles/redraws don't re-decode, and evicts by decoded byte
//  cost when the budget is exceeded.
//
//  DELIBERATELY NOT NSCache: NSCache's eviction is opaque and non-deterministic,
//  which is exactly the property we cannot profile. We want an explicit cost
//  (decoded bytes) and an explicit LRU order so that eviction behaviour under
//  memory pressure is observable and testable.
//
//  ⚠️ STRESS-TEST UNDER PROFILING (Session 7). Eviction under real memory
//  pressure is the single thing in this subsystem most likely to be wrong:
//  the budget number, the per-image cap, the pressure-notification wiring, and
//  the interaction with a tiled render all need to be validated against Instruments
//  on real device memory limits — see Design/CachePolicy.md.
//

import CoreGraphics
import Foundation

// MARK: - ImageCache

public final class ImageCache {

    /// Cache key: the same source at two different target pixel sizes are two
    /// entries (a thumbnail and a full tile are genuinely different decodes). The
    /// href is the interned `StringRef` from the owning document.
    public struct Key: Hashable {
        public var href: StringRef
        public var pixelWidth: Int
        public var pixelHeight: Int
        public init(href: StringRef, pixelWidth: Int, pixelHeight: Int) {
            self.href = href
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    /// Budget in decoded bytes. Default is a placeholder; the real number is a
    /// Session-7 profiling output (a fraction of the app's memory limit).
    /// ⚠️ STRESS-TEST UNDER PROFILING (Session 7).
    public private(set) var budgetBytes: Int

    /// An entry larger than `budgetBytes * maxSingleEntryFraction` is refused
    /// admission: one oversized image must not evict the entire working set to
    /// cache a thing that will itself be evicted on the next insert (cache
    /// thrash). It is decoded, used, and dropped instead.
    /// ⚠️ STRESS-TEST UNDER PROFILING (Session 7): tune the fraction.
    public var maxSingleEntryFraction: Double = 0.5

    public private(set) var currentCostBytes: Int = 0

    /// Intrusive LRU: a dictionary for O(1) lookup + a doubly-linked list for O(1)
    /// move-to-front / evict-from-back. `head` is most-recently-used.
    private final class Node {
        let key: Key
        let image: CGImage
        let cost: Int
        var prev: Node?
        var next: Node?
        init(key: Key, image: CGImage, cost: Int) {
            self.key = key; self.image = image; self.cost = cost
        }
    }
    private var map: [Key: Node] = [:]
    private var head: Node?   // MRU
    private var tail: Node?   // LRU (evicted first)

    public init(budgetBytes: Int) {
        self.budgetBytes = budgetBytes
    }

    // MARK: Lookup / get-or-decode

    /// Fetch the decoded image for `key`, decoding via `decode` on a miss. The
    /// cache never decodes itself — the caller owns format/colour-space policy and
    /// passes a closure — so this file has no image-format dependencies.
    ///
    /// On a hit the entry is promoted to MRU. On a miss the decoded image is
    /// admitted (subject to the single-entry cap) and the budget is enforced by
    /// evicting from the LRU end.
    public func image(for key: Key, decode: () -> CGImage?) -> CGImage? {
        if let node = map[key] {
            moveToFront(node)
            return node.image
        }
        guard let decoded = decode() else { return nil }
        let cost = Self.decodedCost(decoded)

        // Oversized: use but do not admit (see maxSingleEntryFraction).
        if cost > Int(Double(budgetBytes) * maxSingleEntryFraction) {
            return decoded
        }

        let node = Node(key: key, image: decoded, cost: cost)
        map[key] = node
        pushFront(node)
        currentCostBytes += cost
        evictToBudget()
        return decoded
    }

    // MARK: Eviction

    /// Evict LRU entries until within budget. Called after every admission.
    /// ⚠️ STRESS-TEST UNDER PROFILING (Session 7): under a tiled render the same
    /// pass may touch many tiles of one huge image; confirm this loop does not
    /// evict tiles still needed later in the SAME pass (if it does, the fix is a
    /// per-pass pin set, not a bigger budget).
    private func evictToBudget() {
        while currentCostBytes > budgetBytes, let lru = tail {
            remove(lru)
            map[lru.key] = nil
            currentCostBytes -= lru.cost
        }
    }

    /// Drop everything (e.g. document closed).
    public func removeAll() {
        map.removeAll()
        head = nil
        tail = nil
        currentCostBytes = 0
    }

    /// Respond to system memory pressure. The host wires this to a
    /// `DispatchSource` memory-pressure event (or UIApplication memory warning);
    /// this file stays UIKit-free. Default policy: hard purge. A softer policy
    /// (halve the budget, evict to it) is the Session-7 tuning question.
    /// ⚠️ STRESS-TEST UNDER PROFILING (Session 7).
    public func handleMemoryPressure(_ level: MemoryPressureLevel = .critical) {
        switch level {
        case .warning:
            // TODO(Session 7): evict to a reduced budget rather than purge-all.
            let reduced = budgetBytes / 2
            let saved = budgetBytes
            budgetBytes = reduced
            evictToBudget()
            budgetBytes = saved
        case .critical:
            removeAll()
        }
    }

    public enum MemoryPressureLevel { case warning, critical }

    /// Decoded cost in bytes. Assumes 4 bytes/pixel (8-bit RGBA/BGRA), which
    /// matches how we request decodes. PROFILE-CHECK: revisit if we ever decode to
    /// wide-gamut/16-bit surfaces (doubles the cost) — see MemoryModel colour-depth.
    static func decodedCost(_ image: CGImage) -> Int {
        max(1, image.width * image.height * 4)
    }

    // MARK: Intrusive-list plumbing

    private func pushFront(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func remove(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        remove(node)
        pushFront(node)
    }
}
