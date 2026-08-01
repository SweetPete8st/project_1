import Foundation

/// Portable DSP primitives (no Accelerate — ADR-0002; trivially fast at 100 Hz).

/// Direct Form II transposed biquad section.
struct Biquad {
    let b0, b1, b2, a1, a2: Double
    private var z1 = 0.0
    private var z2 = 0.0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    /// 2nd-order Butterworth low-pass (bilinear transform).
    static func lowPass(cutoffHz: Double, sampleRate: Double) -> Biquad {
        let k = tan(.pi * cutoffHz / sampleRate)
        let q = 1.0 / 2.0.squareRoot()
        let norm = 1 / (1 + k / q + k * k)
        return Biquad(
            b0: k * k * norm,
            b1: 2 * k * k * norm,
            b2: k * k * norm,
            a1: 2 * (k * k - 1) * norm,
            a2: (1 - k / q + k * k) * norm)
    }

    /// 2nd-order Butterworth high-pass.
    static func highPass(cutoffHz: Double, sampleRate: Double) -> Biquad {
        let k = tan(.pi * cutoffHz / sampleRate)
        let q = 1.0 / 2.0.squareRoot()
        let norm = 1 / (1 + k / q + k * k)
        return Biquad(
            b0: norm,
            b1: -2 * norm,
            b2: norm,
            a1: 2 * (k * k - 1) * norm,
            a2: (1 - k / q + k * k) * norm)
    }
}

/// 4th-order filter as two cascaded biquads (03 §1 uses 4th-order low-pass @ 6 Hz).
struct Cascade {
    private var sections: [Biquad]

    init(_ sections: [Biquad]) {
        self.sections = sections
    }

    static func lowPass4(cutoffHz: Double, sampleRate: Double) -> Cascade {
        Cascade([
            .lowPass(cutoffHz: cutoffHz, sampleRate: sampleRate),
            .lowPass(cutoffHz: cutoffHz, sampleRate: sampleRate),
        ])
    }

    /// Band-pass as HP(low edge) → LP(high edge), 2nd order each.
    static func bandPass(lowHz: Double, highHz: Double, sampleRate: Double) -> Cascade {
        Cascade([
            .highPass(cutoffHz: lowHz, sampleRate: sampleRate),
            .lowPass(cutoffHz: highHz, sampleRate: sampleRate),
        ])
    }

    mutating func process(_ x: Double) -> Double {
        var v = x
        for i in sections.indices {
            v = sections[i].process(v)
        }
        return v
    }
}

/// Sliding-window RMS via running sum of squares.
struct RunningRMS {
    private var buffer: [Double]
    private var head = 0
    private var filled = 0
    private var sumSquares = 0.0

    init(windowSamples: Int) {
        buffer = [Double](repeating: 0, count: max(1, windowSamples))
    }

    mutating func push(_ x: Double) -> Double {
        sumSquares -= buffer[head] * buffer[head]
        buffer[head] = x
        sumSquares += x * x
        head = (head + 1) % buffer.count
        filled = min(filled + 1, buffer.count)
        // Guard tiny negative drift from float subtraction.
        return (max(0, sumSquares) / Double(filled)).squareRoot()
    }
}

/// Fixed-capacity ring of recent (t, value) samples with time-windowed queries.
struct SampleRing {
    private var times: [Double]
    private var values: [Double]
    private var head = 0
    private var count = 0

    init(capacity: Int) {
        times = [Double](repeating: 0, count: capacity)
        values = [Double](repeating: 0, count: capacity)
    }

    mutating func push(t: Double, value: Double) {
        times[head] = t
        values[head] = value
        head = (head + 1) % times.count
        count = min(count + 1, times.count)
    }

    /// Iterates samples with t in [from, to], oldest first.
    func forEach(from: Double, to: Double, _ body: (Double, Double) -> Void) {
        let n = count
        let cap = times.count
        for i in 0..<n {
            let idx = (head - n + i + cap * 2) % cap
            let t = times[idx]
            if t >= from && t <= to {
                body(t, values[idx])
            }
        }
    }

    func max(from: Double, to: Double) -> Double? {
        var m: Double?
        forEach(from: from, to: to) { _, v in
            if m == nil || v > m! { m = v }
        }
        return m
    }

    func median(from: Double, to: Double) -> Double? {
        var vs = [Double]()
        forEach(from: from, to: to) { _, v in vs.append(v) }
        guard !vs.isEmpty else { return nil }
        vs.sort()
        return vs[vs.count / 2]
    }

    var latest: (t: Double, value: Double)? {
        guard count > 0 else { return nil }
        let idx = (head - 1 + times.count) % times.count
        return (times[idx], values[idx])
    }
}
