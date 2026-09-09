import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var recorder = Recorder()
    @State private var showingRecorder = false

    var body: some View {
        NavigationStack {
            Group {
                if store.notes.isEmpty {
                    ContentUnavailableView(
                        "Sin reuniones todavía",
                        systemImage: "waveform",
                        description: Text("Pulsa el botón para grabar la primera. Todo se procesa en este iPhone.")
                    )
                } else {
                    List {
                        ForEach(store.notes) { note in
                            NavigationLink(value: note.id) {
                                NoteRow(note: note)
                            }
                            .accessibilityIdentifier("note-\(note.title)")
                        }
                        .onDelete { indexes in
                            indexes.map { store.notes[$0] }.forEach(store.delete)
                        }
                    }
                }
            }
            .navigationTitle("Eugenia")
            .navigationDestination(for: UUID.self) { id in
                if let note = store.notes.first(where: { $0.id == id }) {
                    NoteDetailView(note: note)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showingRecorder = true
                } label: {
                    Label("Grabar", systemImage: "mic.circle.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("record-button")
                .padding()
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    StatusBadge()
                }
            }
        }
        .fullScreenCover(isPresented: $showingRecorder) {
            RecordView(recorder: recorder)
        }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title).font(.headline)
            HStack(spacing: 8) {
                Text(note.createdAt, style: .date)
                Text("· \(Int(note.duration / 60)) min")
                Text("· \(note.language.uppercased())")
                if note.state != "summarized" {
                    Text("· \(stateLabel)")
                        .foregroundStyle(note.state == "failed" ? .red : .secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var stateLabel: String {
        switch note.state {
        case "recording":    return "grabando"
        case "transcribed":  return "resumiendo"
        case "failed":       return "error"
        default:             return note.state
        }
    }
}

/// Disponibilidad del LLM, visible siempre. Es la única mitigación que sobrevive
/// del riesgo R1 (plan 11): el iPhone 17e lo soporta, pero Apple Intelligence puede
/// estar desactivado en Ajustes o el modelo descargándose.
private struct StatusBadge: View {
    // La disponibilidad CAMBIA mientras la app está abierta: el modelo termina de
    // descargarse, o el usuario apaga Apple Intelligence en Ajustes. Leerla dentro de
    // `body` dejaba la insignia congelada con el primer valor, porque SwiftUI no tiene
    // ninguna dependencia que le diga que algo cambió — se quedaba verde para siempre.
    //
    // Y hay una razón medida para desconfiar de un solo vistazo: en CI el mismo commit
    // dio `available` y `unavailable(modelNotReady)` en ejecuciones consecutivas.
    @Environment(\.scenePhase) private var scenePhase
    @State private var estado = Summarizer.availabilitySnapshot()

    var body: some View {
        let ok = estado.disponible
        Label(ok ? "IA lista" : "IA no disponible",
              systemImage: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .labelStyle(.iconOnly)
            .foregroundStyle(ok ? .green : .orange)
            .onChange(of: scenePhase) { _, fase in
                if fase == .active { estado = Summarizer.availabilitySnapshot() }
            }
            // .help() no muestra nada en iOS: es de macOS. Para que el estado del
            // modelo sea perceptible hace falta accesibilidad de verdad.
            .accessibilityLabel(ok ? "Modelo de IA disponible" : "Modelo de IA no disponible")
            .accessibilityValue(estado.descripcion)
    }
}
