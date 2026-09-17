import SwiftUI
import WhisperCore

struct ModelPickerView: View {
    @EnvironmentObject var transcription: TranscriptionManager

    var body: some View {
        List {
            ForEach(WhisperModel.allCases) { model in
                ModelRow(model: model, isSelected: model == transcription.model) {
                    transcription.selectModel(model)
                    transcription.warmUp()
                }
            }
        }
        .navigationTitle("Whisper Model")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ModelRow: View {
    let model: WhisperModel
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.displayName)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.brandBlue)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        ModelCatalog.isDownloaded(model) ? "Downloaded" : "\(model.approximateDownloadMB) MB download"
    }
}

#Preview {
    NavigationStack {
        ModelPickerView()
            .environmentObject(TranscriptionManager())
    }
}
