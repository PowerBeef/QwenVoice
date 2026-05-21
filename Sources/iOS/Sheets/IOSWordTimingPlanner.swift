import Foundation

/// Linear word-timing splitter for the Player sheet's karaoke transcript.
/// The engine doesn't emit per-token timestamps, so we approximate by
/// distributing the transcript's words evenly across the audio's duration
/// (per-word count). This matches the design's visual rhythm without
/// requiring engine work.
///
/// Whitespace is preserved as no-op spans so rendering can keep the
/// original spacing intact.
enum IOSWordTimingPlanner {
    static func plan(transcript: String, audioDuration: TimeInterval) -> [IOSWordSpan] {
        guard !transcript.isEmpty, audioDuration > 0 else {
            return [IOSWordSpan(text: transcript, isWhitespace: false, start: 0, end: 0)]
        }

        // Tokenize into runs of whitespace + non-whitespace. Whitespace
        // runs preserve their original characters so the rendered string
        // matches the source verbatim.
        var spans: [IOSWordSpan] = []
        var wordSpanIndices: [Int] = []
        var current = ""
        var currentIsWhitespace: Bool? = nil

        func flush() {
            guard !current.isEmpty, let isWS = currentIsWhitespace else { return }
            spans.append(IOSWordSpan(text: current, isWhitespace: isWS, start: 0, end: 0))
            if !isWS {
                wordSpanIndices.append(spans.count - 1)
            }
            current.removeAll(keepingCapacity: true)
            currentIsWhitespace = nil
        }

        for ch in transcript {
            let isWS = ch.isWhitespace
            if currentIsWhitespace == nil {
                currentIsWhitespace = isWS
            } else if currentIsWhitespace != isWS {
                flush()
                currentIsWhitespace = isWS
            }
            current.append(ch)
        }
        flush()

        guard !wordSpanIndices.isEmpty else {
            // Pure-whitespace transcript; nothing to time.
            for i in spans.indices {
                spans[i].start = 0
                spans[i].end = audioDuration
            }
            return spans
        }

        // Distribute time across word spans evenly. Each word holds its
        // own time slice; whitespace inherits the next word's start so
        // the visual cursor doesn't pause on spaces.
        let slice = audioDuration / Double(wordSpanIndices.count)
        for (i, spanIndex) in wordSpanIndices.enumerated() {
            spans[spanIndex].start = slice * Double(i)
            spans[spanIndex].end = slice * Double(i + 1)
        }
        // Whitespace spans take the surrounding word's timing.
        var lastWordEnd: TimeInterval = 0
        for i in spans.indices {
            if spans[i].isWhitespace {
                spans[i].start = lastWordEnd
                spans[i].end = lastWordEnd
            } else {
                lastWordEnd = spans[i].end
            }
        }
        return spans
    }

    /// Find the index of the span that contains `time`, biased toward the
    /// active word. Returns nil when `time` is outside any span.
    static func activeIndex(in spans: [IOSWordSpan], at time: TimeInterval) -> Int? {
        for (i, span) in spans.enumerated() where !span.isWhitespace {
            if time >= span.start && time < span.end {
                return i
            }
        }
        return nil
    }
}

struct IOSWordSpan: Equatable, Sendable {
    var text: String
    var isWhitespace: Bool
    var start: TimeInterval
    var end: TimeInterval
}
