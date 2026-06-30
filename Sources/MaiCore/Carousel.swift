import Foundation

// Pure index logic for the pinned-cards carousel (one card shown at a time, paged by
// swipe or arrows). Kept out of the UI so it is unit-tested: clamping, paging,
// pinning jumps to the newest so the pin visibly takes, and unpinning keeps a valid
// index. An empty carousel is hidden by the view (index 0, count 0).
public enum Carousel {
    // Keep an index within [0, count-1]; 0 when empty.
    public static func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, index), count - 1)
    }

    // After pinning a new card (appended last), show it.
    public static func afterPin(newCount: Int) -> Int { max(0, newCount - 1) }

    // After unpinning the card at `removedIndex`, keep the view on a sensible neighbor.
    public static func afterUnpin(removedIndex: Int, current: Int, newCount: Int) -> Int {
        guard newCount > 0 else { return 0 }
        let adjusted = removedIndex <= current ? current - 1 : current
        return clamp(adjusted, count: newCount)
    }

    public static func next(_ index: Int, count: Int) -> Int { clamp(index + 1, count: count) }
    public static func prev(_ index: Int, count: Int) -> Int { clamp(index - 1, count: count) }
}
