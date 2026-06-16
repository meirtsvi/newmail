import SwiftUI

/// A compact, scrollable day timeline (à la a calendar day view). Renders the
/// user's events for the invitation's day with overlapping events packed into
/// columns, and overlays the proposed invite slot as a highlighted band.
struct CalendarDayTimeline: View {
    let day: Date
    let events: [CalEvent]
    let inviteStart: Date?
    let inviteEnd: Date?

    private let hourHeight: CGFloat = 44
    private let gutter: CGFloat = 46
    private var cal: Calendar { .current }

    @State private var laneWidth: CGFloat = 1

    var body: some View {
        let startOfDay = cal.startOfDay(for: day)
        let allDay = events.filter(\.isAllDay)
        let timed = events.filter { !$0.isAllDay }
        let packed = Self.pack(timed)

        VStack(alignment: .leading, spacing: 0) {
            headerBar(startOfDay)
            Divider()
            if !allDay.isEmpty {
                allDayRow(allDay)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        // Invite hatch sits behind the gutter labels.
                        if let s = inviteStart, let e = inviteEnd {
                            inviteBand(start: s, end: e, startOfDay: startOfDay)
                        }
                        // Hour grid (gutter labels + lane separators) — defines height.
                        hourGrid
                        // Events overlaid on the lane.
                        ForEach(packed, id: \.ev.id) { item in
                            eventBlock(item, startOfDay: startOfDay)
                        }
                    }
                    .background(widthReader)
                }
                .onAppear {
                    if let s = inviteStart {
                        let hour = max(0, cal.component(.hour, from: s) - 1)
                        proxy.scrollTo(hour, anchor: .top)
                    }
                }
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    // MARK: Header / all-day

    private func headerBar(_ startOfDay: Date) -> some View {
        HStack {
            Text(TimeZone.current.abbreviation() ?? "")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(startOfDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func allDayRow(_ events: [CalEvent]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("all-day").font(.caption2).foregroundStyle(.secondary).frame(width: gutter - 8, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(events) { ev in
                    Text(ev.title).font(.caption).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    // MARK: Grid

    /// One row per hour: the bold gutter label plus the lane's top separator.
    /// This single VStack defines the scroll content's height (24 × hourHeight),
    /// so the timeline always starts at 00:00 and scrolls cleanly to 23:00.
    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 0) {
                    Text(hourLabel(hour))
                        .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: gutter, height: hourHeight, alignment: .topTrailing)
                        .padding(.trailing, 4)
                    Divider().frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(height: hourHeight)
                .id(hour)
            }
        }
    }

    private var gutterWidth: CGFloat { gutter + 4 }

    private var widthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { laneWidth = max(1, geo.size.width - gutterWidth) }
                .onChange(of: geo.size.width) { _, w in laneWidth = max(1, w - gutterWidth) }
        }
    }

    // MARK: Events

    private func eventBlock(_ item: Positioned, startOfDay: Date) -> some View {
        let colW = max(1, (laneWidth - 4) / CGFloat(item.cols))
        return Text(item.ev.title)
            .font(.caption2)
            .lineLimit(3)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .frame(width: colW - 2, height: max(16, height(item.ev.start, item.ev.end)), alignment: .topLeading)
            .background(Color.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .leading) { Rectangle().fill(Color.blue).frame(width: 2) }
            .offset(x: gutterWidth + CGFloat(item.col) * colW + 2, y: offset(item.ev.start, from: startOfDay))
    }

    private func inviteBand(start: Date, end: Date, startOfDay: Date) -> some View {
        DiagonalStripes(spacing: 6, lineWidth: 2)
            .stroke(Color.gray.opacity(0.45), lineWidth: 1.5)
            .background(Color.gray.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.gray.opacity(0.35), lineWidth: 1))
            .frame(width: gutter, height: max(18, height(start, end)))
            .offset(x: 0, y: offset(start, from: startOfDay))
    }

    // MARK: Geometry helpers

    private func offset(_ date: Date, from startOfDay: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(startOfDay) / 60) * (hourHeight / 60)
    }

    private func height(_ start: Date, _ end: Date) -> CGFloat {
        CGFloat(max(0, end.timeIntervalSince(start)) / 60) * (hourHeight / 60)
    }

    private func hourLabel(_ hour: Int) -> String {
        var c = DateComponents(); c.hour = hour
        let date = cal.date(from: c) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    // MARK: Overlap packing

    struct Positioned { let ev: CalEvent; let col: Int; let cols: Int }

    /// Greedy interval partitioning: groups overlapping events into clusters and
    /// assigns each a column so they render side by side.
    static func pack(_ events: [CalEvent]) -> [Positioned] {
        let sorted = events.sorted { $0.start < $1.start }
        var result: [Positioned] = []
        var i = 0
        while i < sorted.count {
            var clusterEnd = sorted[i].end
            var j = i + 1
            while j < sorted.count && sorted[j].start < clusterEnd {
                clusterEnd = max(clusterEnd, sorted[j].end)
                j += 1
            }
            let cluster = Array(sorted[i..<j])
            var colEnds: [Date] = []
            var cols: [Int] = []
            for ev in cluster {
                if let c = colEnds.firstIndex(where: { $0 <= ev.start }) {
                    colEnds[c] = ev.end; cols.append(c)
                } else {
                    colEnds.append(ev.end); cols.append(colEnds.count - 1)
                }
            }
            let total = max(1, colEnds.count)
            for (k, ev) in cluster.enumerated() {
                result.append(Positioned(ev: ev, col: cols[k], cols: total))
            }
            i = j
        }
        return result
    }
}

/// A repeating diagonal hatch pattern, used to mark the clicked event's slot
/// without obscuring existing events with a title.
private struct DiagonalStripes: Shape {
    var spacing: CGFloat = 6
    var lineWidth: CGFloat = 2

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = spacing + lineWidth
        // Draw lines from bottom-left to top-right, sweeping across so the whole
        // rect is covered regardless of its aspect ratio.
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.height))
            path.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += step
        }
        return path
    }
}
