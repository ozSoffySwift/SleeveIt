import WidgetKit
import SwiftUI

/// Timeline entry backed by the shared snapshot the app writes on each My List
/// change.
struct SleeveEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot
}

struct SleeveProvider: TimelineProvider {
    func placeholder(in context: Context) -> SleeveEntry {
        SleeveEntry(date: .now, snapshot: SharedSnapshot(
            totalSleeves: 196, topLines: ["170× Standard", "26× Mini"], gamesToSleeve: 1, updatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (SleeveEntry) -> Void) {
        completion(SleeveEntry(date: .now, snapshot: SharedStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SleeveEntry>) -> Void) {
        // The app pushes fresh data via reloadAllTimelines on save, so a slow
        // hourly refresh is only a backstop.
        let entry = SleeveEntry(date: .now, snapshot: SharedStore.load())
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct SleeveItWidgetView: View {
    var entry: SleeveEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: SharedSnapshot { entry.snapshot }

    var body: some View {
        if snapshot.totalSleeves == 0 {
            emptyState
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up.fill")
                Text("Sleeves to buy")
                    .font(.system(size: 12, weight: .semibold))
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.secondary)

            Text("\(snapshot.totalSleeves)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            if family != .systemSmall {
                ForEach(snapshot.topLines.prefix(3), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }
            } else if let first = snapshot.topLines.first {
                Text(first)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            Text("\(snapshot.gamesToSleeve) game\(snapshot.gamesToSleeve == 1 ? "" : "s") to sleeve")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            Text("All sleeved")
                .font(.system(size: 15, weight: .semibold))
            Text("Nothing to buy")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SleeveItWidget: Widget {
    let kind = "SleeveItWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SleeveProvider()) { entry in
            SleeveItWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .tint(Color(red: 28 / 255, green: 100 / 255, blue: 50 / 255))
        }
        .configurationDisplayName("Sleeves to Buy")
        .description("Your SleeveIt shopping-list total at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
