import SwiftUI

/// Ask AI con citas (plan 5.5). Sobre una reunión (`scope`) o sobre todas.
/// Recuperación híbrida en el iPhone + respuesta del modelo on-device, con los
/// segundos citados enlazados al audio. Las preguntas globales ("¿de qué trató?")
/// se contestan con el resumen, no con recuperación.
struct AskAIView: View {
    let scope: UUID?
    var embedded = false

    @EnvironmentObject private var store: Store
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss

    struct Exchange: Identifiable {
        let id = UUID()
        var question: String
        var answer: String
        var citations: [SearchHit]
    }

    @State private var question = ""
    @State private var history: [Exchange] = []
    @State private var thinking = false

    var body: some View {
        if embedded {
            conversation
        } else {
            NavigationStack {
                ScrollView { conversation.padding() }
                    .navigationTitle("Preguntar")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            if history.isEmpty {
                Text(scope == nil
                     ? "Pregunta sobre cualquiera de tus reuniones: «¿qué quedó Javier en enviar?», «¿cuándo hablamos del presupuesto?»"
                     : "Pregunta sobre esta reunión. La respuesta cita el momento exacto del audio.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(history) { ex in
                VStack(alignment: .leading, spacing: 6) {
                    Text(ex.question).font(.callout.weight(.semibold))
                    Text(ex.answer).textSelection(.enabled)
                    ForEach(ex.citations) { hit in
                        Button {
                            if !embedded { dismiss() }
                            router.open(noteID: hit.noteID, at: hit.atSeconds)
                        } label: {
                            Label("\(scope == nil ? hit.noteTitle + " · " : "")\(TimeFormat.mmss(hit.atSeconds))",
                                  systemImage: "play.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                TextField("Tu pregunta", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ask-field")
                    .onSubmit(ask)
                if thinking {
                    ProgressView()
                } else {
                    Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Preguntar")
                }
            }
            if !Summarizer.isAvailable {
                Text("Las respuestas necesitan Apple Intelligence. Sin él, se muestran los fragmentos más relevantes.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        question = ""
        let notes = scope.flatMap { id in store.note(id).map { [$0] } } ?? store.notes
        Task {
            thinking = true
            defer { thinking = false }
            // Pregunta global sobre UNA reunión: el resumen ya la contesta.
            if let only = notes.first, notes.count == 1, SearchIndex.isGlobalQuestion(q), !only.summaryOverview.isEmpty {
                history.append(Exchange(question: q, answer: only.summaryOverview, citations: []))
                return
            }
            let hits = SearchIndex.shared.search(q, in: notes, limit: 8)
            guard !hits.isEmpty else {
                history.append(Exchange(question: q, answer: String(localized: "No encontré nada sobre eso en tus reuniones."), citations: []))
                return
            }
            guard Summarizer.isAvailable else {
                history.append(Exchange(question: q, answer: String(localized: "Fragmentos más relevantes:"),
                                        citations: Array(hits.prefix(5))))
                return
            }
            do {
                let lang = notes.first?.language ?? "es"
                let answer = try await Summarizer.answer(question: q, passages: hits, language: lang)
                // Las citas del modelo se validan contra lo recuperado: un segundo que
                // no está en los fragmentos no se enseña como prueba.
                let cited = hits.filter { h in answer.citations.contains { abs(Double($0) - h.atSeconds) < 2 } }
                history.append(Exchange(question: q, answer: answer.answer,
                                        citations: cited.isEmpty ? Array(hits.prefix(3)) : cited))
            } catch {
                history.append(Exchange(question: q, answer: Recorder.userMessage(for: error), citations: Array(hits.prefix(3))))
            }
        }
    }
}
