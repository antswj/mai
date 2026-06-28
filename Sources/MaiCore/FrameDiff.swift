import Foundation

// Cheap perceptual change detection. The capture layer downscales a frame to a
// small grayscale grid (9 wide by 8 tall) and calls dHash here; comparing two
// hashes by Hamming distance tells us whether the screen meaningfully changed.
// Pure integer math, no platform dependency, fully testable.
public enum FrameDiff {

    /// Difference hash from a 9x8 grayscale buffer (72 bytes, row-major). For each
    /// of the 8 rows, compare 8 adjacent horizontal pairs (9 columns), giving 64 bits.
    public static func dHash9x8(_ bytes: [UInt8]) -> UInt64 {
        precondition(bytes.count >= 72, "dHash9x8 needs at least 72 bytes (9x8)")
        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                let left = bytes[row * 9 + col]
                let right = bytes[row * 9 + col + 1]
                if left > right { hash |= (1 << bit) }
                bit += 1
            }
        }
        return hash
    }

    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Fraction of the 64 bits that differ (0.0 identical, 1.0 fully different).
    public static func changeFraction(_ a: UInt64, _ b: UInt64) -> Double {
        Double(hammingDistance(a, b)) / 64.0
    }

    /// True when the change exceeds the configured threshold (a meaningful change).
    public static func changed(_ a: UInt64, _ b: UInt64, threshold: Double) -> Bool {
        changeFraction(a, b) > threshold
    }
}
