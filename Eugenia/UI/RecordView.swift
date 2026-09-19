import SwiftUI

struct RecordView: View {
    var initialTitle: String?
    var eventID: String?

    @ObservedObject private var recorder = Recorder.shared
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            header

            Text(TimeFormat.mmss(recorder.elapsed))
                .font(.system(size: 56, weight: .light, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("Tiempo grabado")
                .accessibilityValue(TimeFormat.mmss(recorder.elapsed))

            LevelMeterView(level: recorder.state == .recording ? Double(recorder.level) : 0)
                .frame(height: 28)
                .padding(.horizontal)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(recorder.liveText)
                        // Los volátiles en gris: pueden cambiar antes de consolidarse.
                        Text(recorder.volatileText).foregroundStyle(.secondary)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .onChange(of: recorder.liveText) { _, _ in proxy.scrollTo("end") }
            }

            statusMessage

            actions
        }
        .padding(.vertical, 24)
        .task {
            // Abrir esta pantalla = grabar. Si la anterior terminó (bien o con error), se
            // empieza una nueva; si hay una en curso, solo se vuelve a ella.
            recorder.resetIfFinished()
            guard recorder.state == .idle else { return }
            startRecording()
        }
    }

    private func startRecording() {
        var title = initialTitle
        var attendees: [String] = []
        var event = eventID
        // Reunión del calendario en curso: título y asistentes rellenados solos.
        if let m = CalendarService.shared.currentMeeting() {
            if title == nil { title = m.title }
            attendees = m.attendees
            if event == nil { event = m.id }
        }
        router.pendingTitle = nil
        router.pendingEventID = nil
        recorder.start(title: title, attendees: attendees, calendarEventID: event)
    }

    @ViewBuilder private var header: some View {
        switch recorder.state {
        case .recording:
            // Aviso de grabación siempre visible (plan 5.1 y sección 12).
            Label("GRABANDO", systemImage: "record.circle")
                .font(.footnote.weight(.bold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.red, in: Capsule())
                .foregroundStyle(.white)
                .accessibilityIdentifier("recording-badge")
        case .interrupted:
            Label("EN PAUSA: llamada o aviso del sistema", systemImage: "pause.circle")
                .font(.footnote.weight(.bold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.orange, in: Capsule())
                .foregroundStyle(.white)
        case .starting:
            HStack { ProgressView(); Text("Preparando el micrófono y el modelo de voz…") }.font(.callout)
        case .stopping:
            HStack { ProgressView(); Text("Guardando…") }.font(.callout)
        default:
            EmptyView()
        }
        if recorder.state.isActive {
            Text("Recuerda avisar a los asistentes de que se está grabando.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusMessage: some View {
        if case .failed(let message) = recorder.state {
            Text(message)
                .font(.callout).foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier("record-error")
        } else if recorder.state == .idle, recorder.lastFinishedNoteID != nil {
            VStack(spacing: 8) {
                Label("Reunión guardada", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("El resumen se prepara en segundo plano; puedes grabar otra ya.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 10) {
            switch recorder.state {
            case .recording, .interrupted:
                Button(role: .destructive) {
                    Task { await recorder.stop() }
                } label: {
                    Text("Parar").frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .accessibilityIdentifier("record-toggle")
            case .starting:
                Button("Cancelar") { recorder.cancelStart() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("record-toggle")
            case .stopping:
                EmptyView()
            case .idle, .failed:
                if let id = recorder.lastFinishedNoteID, recorder.state == .idle {
                    Button {
                        dismiss()
                        router.open(noteID: id)
                    } label: {
                        Text("Ver la reunión").frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Grabar otra") { startRecording() }.buttonStyle(.bordered)
                }
                if case .failed = recorder.state {
                    Button("Reintentar") { recorder.resetIfFinished(); startRecording() }
                        .buttonStyle(.borderedProminent)
                }
                Button {
                    dismiss()
                } label: {
                    Text("Cerrar").frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("record-toggle")
            }
        }
        .padding(.horizontal)
    }
}

struct LevelMeterView: View {
    let level: Double
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { i in
                    let on = Double(i) / 24 < level
                    Capsule()
                        .fill(on ? Color.red : Color.secondary.opacity(0.25))
                        .frame(width: max(2, (geo.size.width - 69) / 24))
                }
            }
        }
        .animation(.linear(duration: 0.2), value: level)
        .accessibilityHidden(true)
    }
}
