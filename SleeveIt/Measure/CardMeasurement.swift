import Foundation

/// A physical card measurement, always stored in millimetres.
struct CardMeasurement: Equatable {
    var widthMM: Double
    var heightMM: Double

    /// Confidence 0…1, derived from how tightly repeated samples agreed.
    var confidence: Double

    /// Normalises orientation so a card measured sideways still reads portrait.
    var normalized: CardMeasurement {
        guard widthMM > heightMM else { return self }
        return CardMeasurement(widthMM: heightMM, heightMM: widthMM, confidence: confidence)
    }
}

/// Rolling window of raw samples that decides when a measurement has settled.
///
/// ARKit's per-frame geometry is noisy: individual raycasts jitter by a
/// millimetre or two even on a still hand. Rather than trust any single frame,
/// this collects a window of samples and only reports a lock once the spread
/// across that window is tight enough to be meaningful.
struct MeasurementStabilizer {
    /// Samples required before a lock can be reported.
    var windowSize: Int = 12

    /// Maximum peak-to-peak spread, in mm, for a window to count as stable.
    var toleranceMM: Double = 0.8

    private var samples: [CardMeasurement] = []

    init(windowSize: Int = 12, toleranceMM: Double = 0.8) {
        self.windowSize = windowSize
        self.toleranceMM = toleranceMM
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Feeds one raw sample in. Returns a settled measurement once the window is
    /// both full and tight, otherwise nil.
    mutating func accept(_ sample: CardMeasurement) -> CardMeasurement? {
        samples.append(sample.normalized)
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }
        guard samples.count == windowSize else { return nil }

        let widths = samples.map(\.widthMM)
        let heights = samples.map(\.heightMM)
        let widthSpread = (widths.max() ?? 0) - (widths.min() ?? 0)
        let heightSpread = (heights.max() ?? 0) - (heights.min() ?? 0)
        let spread = max(widthSpread, heightSpread)
        guard spread <= toleranceMM else { return nil }

        // Median is robust to the occasional bad raycast in an otherwise good window.
        let width = widths.sorted()[widths.count / 2]
        let height = heights.sorted()[heights.count / 2]
        let confidence = max(0, 1 - spread / toleranceMM)
        return CardMeasurement(widthMM: width, heightMM: height, confidence: confidence)
    }

    /// The current best guess, for the live readout before a lock.
    var current: CardMeasurement? {
        guard let last = samples.last else { return nil }
        return last
    }
}

// MARK: - Matching

enum SleeveMatcher {
    /// The nearest catalog size by Euclidean distance in mm.
    ///
    /// Card sizes cluster tightly (63.5×88 vs 65×100 vs 59×92), so plain nearest
    /// neighbour is both sufficient and predictable.
    static func nearest(to measurement: CardMeasurement, in sizes: [SleeveSize]) -> SleeveSize? {
        sizes.min { lhs, rhs in
            distance(measurement, lhs) < distance(measurement, rhs)
        }
    }

    static func distance(_ measurement: CardMeasurement, _ size: SleeveSize) -> Double {
        let dw = size.widthMM - measurement.widthMM
        let dh = size.heightMM - measurement.heightMM
        return (dw * dw + dh * dh).squareRoot()
    }

    /// Whether the match is close enough to recommend without a caveat.
    /// Sleeves need a little slack, so anything within ~2.5mm is a confident fit.
    static func isConfident(_ measurement: CardMeasurement, _ size: SleeveSize) -> Bool {
        distance(measurement, size) <= 2.5
    }
}
