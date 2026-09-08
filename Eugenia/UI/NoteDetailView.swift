import SwiftUI

struct NoteDetailView: View {
    let note: Note

    var body: some View {
        List {
            if note.state == "failed", let failure = note.failure {
                Section("Error") {
                    Text(failure).font(.caption.monospaced()).foregroundStyle(.red)
                }
            }

            if !note.summaryOverview.isEmpty {
                Section("Resumen") { Text(note.summaryOverview) }
            }

            if !note.decisions.isEmpty {
                Section("Decisiones") {
                    ForEach(note.decisions, id: \.self) { Text($0) }
                }
            }

            if !note.actionItems.isEmpty {
                Section("Tareas") {
                    ForEach(note.actionItems, id: \.text) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text)
                            HStack(spacing: 6) {
                                Text(item.status)
                                if !item.assignee.isEmpty { Text("· \(item.assignee)") }
                                Text("· \(item.atSeconds / 60):" + String(format: "%02d", item.atSeconds % 60))
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Transcripción") {
                Text(note.transcript.isEmpty ? "(vacía)" : note.transcript)
                    .font(.callout)
            }
        }
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
