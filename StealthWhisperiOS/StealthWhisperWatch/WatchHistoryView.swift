import SwiftUI

/// Compact read-only view of the shared transcription history, synced via
/// iCloud Documents from the iPhone and Mac apps.
struct WatchHistoryView: View {
    @ObservedObject var history: HistoryStore

    var body: some View {
        List {
            if history.entries.isEmpty {
                Text("No transcripts yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history.entries.prefix(15)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: sourceIcon(entry.source))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Color.brandBlue)
                            Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.displayTitle)
                            .font(.system(size: 12))
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("History")
    }

    private func sourceIcon(_ source: HistorySource) -> String {
        switch source {
        case .iphone: return "iphone"
        case .watch: return "applewatch"
        case .mac: return "desktopcomputer"
        }
    }
}

#Preview {
    NavigationStack {
        WatchHistoryView(history: HistoryStore())
    }
}
