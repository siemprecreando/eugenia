import SwiftUI

struct RecordView: View {
    @ObservedObject var recorder: Recorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            // Aviso de grabación siempre visible. No es solo cumplimiento normativo,
            // es diseño ético y es el producto (plan 5.1 y sección 12).
            if recorder.state == .recording {
                Label("GRABANDO", systemImage: "record.circle")
                    .font(.footnote.weight(.bold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.red, in: Capsule())
                    .foregroundStyle(.white)
            }

            Text(timeString)
                .font(.system(size: 56, weight: .light, design: .rounded))
                .monospacedDigit()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(recorder.liveText)
                    // Los volátiles en gris: pueden cambiar antes de consolidarse.
                    Text(recorder.volatileText).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }

            if case .failed(let message) = recorder.state {
                Text(message)
                    .font(.caption).foregroundStyle(.red)
                    .padding(.horizontal)
            }
            if case .processing(let message) = recorder.state {
                HStack { ProgressView(); Text(message) }.font(.callout)
            }

            Button(role: recorder.state == .recording ? .destructive : .cancel) {
                Task {
                    if recorder.state == .recording {
                        await recorder.stop()
                    } else {
                        dismiss()
                    }
                }
            } label: {
                Text(recorder.state == .recording ? "Parar" : "Cerrar")
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
        .padding(.vertical, 32)
        .task {
            if recorder.state == .idle { await recorder.start() }
        }
    }

    private var timeString: String {
        let total = Int(recorder.elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
