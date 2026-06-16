import SwiftUI

// MARK: - Spine layout constants

enum SpineLayout {
    static let dotSize:     CGFloat = 7
    static let dotTopInset: CGFloat = 20
    static var dotCenterY:  CGFloat { dotTopInset + dotSize / 2 }
}

// MARK: - Color helper

extension Color {
    init?(hexString: String) {
        let s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >>  8) & 0xFF) / 255,
            blue:  Double( v        & 0xFF) / 255
        )
    }
}

// MARK: - LaneGraph

/// Pure value computed once from session data.
/// Each lane breaks into contiguous segments — non-adjacent active sessions
/// get separate fork/merge pairs rather than one long unbroken line.
struct LaneGraph {

    struct Lane: Identifiable {
        let tag:            Tag
        let color:          Color
        let col:            Int              // horizontal column (0 = innermost)
        let span:           ClosedRange<Int> // full extent, used only for packing
        /// Contiguous runs of active session indices, sorted by lowerBound ascending
        /// (lowerBound = newest/top, upperBound = oldest/bottom within each run).
        let segments:       [ClosedRange<Int>]
        let activeSessions: Set<Int>

        var id: String { tag.id }

        /// True when the only segment is a single session at the very top — nothing to draw yet.
        var isSingleCurrent: Bool {
            segments.count == 1 && segments[0].count == 1 && segments[0].lowerBound == 0
        }
    }

    let lanes: [Lane]

    static let empty = LaneGraph(lanes: [])
    init(lanes: [Lane]) { self.lanes = lanes }

    init(sessions: [TimelineSession],
         tagMap: [String: [Tag]],
         selectedTagIds: Set<String>) {

        guard !sessions.isEmpty else { self.lanes = []; return }

        // 1. One pass: span ranges + active-session sets.
        var spanMap:   [String: (lower: Int, upper: Int)] = [:]
        var activeMap: [String: Set<Int>]                 = [:]
        for (i, session) in sessions.enumerated() {
            let tagIds = Set(session.highlights.flatMap { tagMap[$0.id] ?? [] }.map(\.id))
            for tid in tagIds {
                if let cur = spanMap[tid] {
                    spanMap[tid] = (Swift.min(cur.lower, i), Swift.max(cur.upper, i))
                } else {
                    spanMap[tid] = (i, i)
                }
                activeMap[tid, default: []].insert(i)
            }
        }
        let spans = spanMap.mapValues { $0.lower...$0.upper }

        // 2. Collect + filter tags.
        var seenTags: [String: Tag] = [:]
        for tags in tagMap.values {
            for tag in tags where spans[tag.id] != nil { seenTags[tag.id] = tag }
        }
        var sortedTags = seenTags.values.sorted { $0.createdAt < $1.createdAt }
        if !selectedTagIds.isEmpty {
            sortedTags = sortedTags.filter { selectedTagIds.contains($0.id) }
        }
        guard !sortedTags.isEmpty else { self.lanes = []; return }

        // 3. Greedy interval coloring on full spans.
        let ordered = sortedTags
            .compactMap { tag -> (Tag, ClosedRange<Int>)? in
                guard let span = spans[tag.id] else { return nil }
                return (tag, span)
            }
            .sorted { $0.1.lowerBound < $1.1.lowerBound }

        var laneEnd:     [Int: Int]                                     = [:]
        var assignments: [(tag: Tag, span: ClosedRange<Int>, col: Int)] = []

        for (tag, span) in ordered {
            var col = 0
            while let lastUpper = laneEnd[col], span.lowerBound <= lastUpper { col += 1 }
            laneEnd[col] = span.upperBound
            assignments.append((tag, span, col))
        }

        // 4. Stable palette + build lanes with contiguous segments.
        let palette: [Color] = [.blue, .purple, .green, .orange, .pink,
                                 .teal, .indigo, .mint, .cyan, .red]
        self.lanes = assignments.map { pair in
            let color = pair.tag.color.flatMap { Color(hexString: $0) }
                        ?? palette[abs(pair.tag.id.hashValue) % palette.count]
            let active   = activeMap[pair.tag.id] ?? []
            let segments = LaneGraph.makeSegments(from: active)
            return Lane(tag:            pair.tag,
                        color:          color,
                        col:            pair.col,
                        span:           pair.span,
                        segments:       segments,
                        activeSessions: active)
        }
    }

    /// Groups a set of session indices into contiguous runs.
    /// Indices are sorted ascending (0 = newest). A "gap" of more than 1 between
    /// consecutive indices starts a new segment.
    /// Returns segments sorted by lowerBound ascending (topmost first).
    private static func makeSegments(from active: Set<Int>) -> [ClosedRange<Int>] {
        let sorted = active.sorted()
        guard !sorted.isEmpty else { return [] }
        var segments: [ClosedRange<Int>] = []
        var lo = sorted[0], hi = sorted[0]
        for idx in sorted.dropFirst() {
            if idx == hi + 1 { hi = idx }
            else { segments.append(lo...hi); lo = idx; hi = idx }
        }
        segments.append(lo...hi)
        return segments  // sorted by lowerBound ascending (smallest = newest = topmost)
    }
}

// MARK: - SessionNodeKey

/// Each SessionRow reports its spine-node Y in the "timeline" coordinate space.
struct SessionNodeKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - LaneCanvas

/// Single canvas over the full LazyVStack.
/// Each tag lane is split into contiguous segments; non-adjacent active sessions
/// get their own fork + merge pair, like separate commits on a branch.
struct LaneCanvas: View {
    let graph:         LaneGraph
    let nodePositions: [Int: CGFloat]
    let spineX:        CGFloat
    let hideSpine:     Bool

    private let laneWidth: CGFloat = 6
    private let outerPad:  CGFloat = 2
    private let lineW:     CGFloat = 1.5
    private let dotR:      CGFloat = 2.5
    /// Minimum arch height so even single-session segments are visible.
    private let minDrop:   CGFloat = 12

    var body: some View {
        Canvas { ctx, _ in
            guard !hideSpine else { return }

            for lane in graph.lanes {
                let laneX = outerPad + CGFloat(lane.col) * laneWidth + laneWidth / 2
                let style = StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round)

                // Single-session lane: just a dot at the node — no bezier, no trunk.
                if lane.activeSessions.count == 1,
                   let sessionIdx = lane.activeSessions.first,
                   let nodeY = nodePositions[sessionIdx] {
                    let rect = CGRect(x: laneX - dotR, y: nodeY - dotR,
                                      width: dotR * 2, height: dotR * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(lane.color))
                    continue
                }

                guard lane.activeSessions.count > 1 else { continue }

                // Track fork/merge endpoints so dots are suppressed there.
                var skipForDot: Set<Int> = []

                for segment in lane.segments {
                    let isSingle  = segment.count == 1
                    let isOpenTop = segment.lowerBound == 0

                    // Single-session segments render as a dot only — no bezier.
                    // Let them fall through to the dot pass below (don't add to skipForDot).
                    if isSingle { continue }

                    guard let forkY = nodePositions[segment.upperBound],
                          let tipY  = nodePositions[segment.lowerBound]
                    else { continue }

                    let drop = min(20, max(minDrop, (forkY - tipY) * 0.25))

                    // Only suppress dots at endpoints of segments we actually draw beziers for.
                    skipForDot.insert(segment.upperBound)
                    if !isOpenTop { skipForDot.insert(segment.lowerBound) }

                    var p = Path()

                    // Fork bezier — spine → lane at the oldest session.
                    p.move(to: CGPoint(x: spineX, y: forkY))
                    p.addCurve(
                        to:       CGPoint(x: laneX, y: forkY - drop),
                        control1: CGPoint(x: laneX, y: forkY),
                        control2: CGPoint(x: laneX, y: forkY)
                    )

                    // Vertical trunk.
                    p.addLine(to: CGPoint(x: laneX, y: isOpenTop ? tipY : tipY + drop))

                    // Merge bezier — lane → spine at the newest session (if not open).
                    if !isOpenTop {
                        p.addCurve(
                            to:       CGPoint(x: spineX, y: tipY),
                            control1: CGPoint(x: laneX, y: tipY),
                            control2: CGPoint(x: laneX, y: tipY)
                        )
                    }

                    ctx.stroke(p, with: .color(lane.color), style: style)
                }

                // Dots at active intermediate sessions (not fork or merge endpoints).
                for sessionIdx in lane.activeSessions {
                    guard let dotY = nodePositions[sessionIdx],
                          !skipForDot.contains(sessionIdx)
                    else { continue }
                    let rect = CGRect(x: laneX - dotR, y: dotY - dotR,
                                      width: dotR * 2, height: dotR * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(lane.color))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
