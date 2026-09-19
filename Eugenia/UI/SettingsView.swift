import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var voices = VoiceprintStore.shared
    @State private var confirmWipeVoices = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Grabación") {
                    Picker("Idioma de la reunión", selection: $settings.recordingLanguage) {
                        Text("Automático (el del iPhone)").tag("auto")
                        Text("Español").tag("es")
                        Text("Inglés").tag("en")
                    }
                    Picker("Micrófono", selection: $settings.micProfile) {
                        Text("Sala (varias personas)").tag(MicProfile.room.rawValue)
                        Text("Llamada en altavoz").tag(MicProfile.speakerCall.rawValue)
                        Text("Dictado (una voz cerca)").tag(MicProfile.dictation.rawValue)
                    }
                    Toggle("Mantener la pantalla encendida al grabar", isOn: $settings.keepScreenOn)
                }
                Section {
                    Picker("Plantilla por defecto", selection: $settings.defaultTemplate) {
                        ForEach(SummaryTemplate.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Tono", selection: $settings.summaryTone) {
                        Text("Neutro").tag("neutral")
                        Text("Formal").tag("formal")
                        Text("Cercano").tag("casual")
                        Text("Telegráfico").tag("concise")
                    }
                    LabeledContent("Apple Intelligence", value: Summarizer.isAvailable ? String(localized: "Disponible") : String(localized: "No disponible"))
                } header: { Text("Resumen") } footer: {
                    Text("Los resúmenes se hacen en este iPhone. Eugenia nunca usa Private Cloud Compute ni servidores.")
                }
                Section {
                    Toggle("Separar hablantes", isOn: $settings.diarizationEnabled)
                    Toggle("Reconocer voces entre reuniones", isOn: $settings.voiceprintsEnabled)
                    if !voices.people.isEmpty {
                        ForEach(voices.people) { p in
                            Text(p.name).swipeActions { Button("Olvidar", role: .destructive) { voices.remove(p) } }
                        }
                        Button("Olvidar todas las voces", role: .destructive) { confirmWipeVoices = true }
                    }
                } header: { Text("Hablantes") } footer: {
                    Text("Separar hablantes descarga una vez unos modelos (~50 MB) y después funciona sin conexión. El reconocimiento de voces guarda una huella de voz por persona: es un dato biométrico, solo se guarda en este iPhone, no entra en copias de seguridad y se borra aquí.")
                }
                Section("Almacenamiento y privacidad") {
                    NavigationLink("Gestión de espacio") { StorageView() }
                    NavigationLink("Copia cifrada") { BackupView() }
                    Toggle("Bloquear con Face ID", isOn: $settings.faceIDLock)
                }
                Section {
                    Toggle("Avisarme antes de reuniones del calendario", isOn: Binding(
                        get: { settings.calendarSuggestions },
                        set: { on in
                            Task {
                                if on { _ = await CalendarService.shared.requestAccess(); _ = await Notifier.requestPermission() }
                                settings.calendarSuggestions = on && CalendarService.shared.hasAccess
                                CalendarService.shared.scheduleSuggestions()
                            }
                        }))
                } header: { Text("Calendario") } footer: {
                    Text("Con acceso al calendario, el título y los asistentes se rellenan solos al grabar durante una reunión.")
                }
                Section("Automatización") {
                    NavigationLink("Enviar a un CRM con Atajos") { AutomationView() }
                }
                Section("Legal") {
                    NavigationLink("Privacidad") { LegalView(kind: .privacy) }
                    NavigationLink("Condiciones de uso") { LegalView(kind: .terms) }
                    NavigationLink("Grabar a otras personas") { LegalView(kind: .recording) }
                }
                Section("Acerca de") {
                    LabeledContent("Versión", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    LabeledContent("Compilación", value: String((Bundle.main.object(forInfoDictionaryKey: "EugeniaCommit") as? String ?? "local").prefix(7)))
                }
            }
            .navigationTitle("Ajustes")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
            .confirmationDialog("¿Olvidar todas las voces?", isPresented: $confirmWipeVoices, titleVisibility: .visible) {
                Button("Olvidar todas", role: .destructive) { voices.removeAll() }
            }
        }
    }
}

// MARK: - Gestión de espacio (plan 8.3)

struct StorageView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmNote: Note?

    private struct AudioRow: Identifiable {
        let note: Note
        let bytes: Int64
        var id: UUID { note.id }
    }

    private var withAudio: [AudioRow] {
        store.notes.filter { $0.audioState == "present" && !$0.allAudioFiles.isEmpty }
            .map { AudioRow(note: $0, bytes: store.audioBytes(of: $0)) }
            .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        let total = withAudio.reduce(Int64(0)) { $0 + $1.bytes }
        Form {
            Section {
                LabeledContent("Audio guardado", value: ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                LabeledContent("Espacio libre en el iPhone", value: "\(store.freeDiskMB()) MB")
            }
            Section {
                Picker("Borrar el audio pasados", selection: $settings.audioRetentionDays) {
                    Text("Nunca").tag(0)
                    Text("7 días").tag(7)
                    Text("30 días").tag(30)
                    Text("90 días").tag(90)
                    Text("1 año").tag(365)
                }
                Button("Aplicar ahora") { RetentionPolicy.sweep() }
            } header: { Text("Limpieza automática") } footer: {
                Text("Solo se borra el AUDIO de reuniones ya resumidas. La transcripción y el resumen se quedan. Las favoritas no se tocan.")
            }
            Section("Audio por reunión") {
                ForEach(withAudio) { row in
                    let note = row.note
                    HStack {
                        VStack(alignment: .leading) {
                            Text(note.title).lineLimit(1)
                            Text(note.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file)).font(.caption)
                    }
                    .swipeActions { Button("Borrar audio", role: .destructive) { confirmNote = note } }
                }
            }
        }
        .navigationTitle("Gestión de espacio")
        .confirmationDialog("¿Borrar el audio de esta reunión?", isPresented: Binding(get: { confirmNote != nil }, set: { if !$0 { confirmNote = nil } }),
                            titleVisibility: .visible) {
            Button("Borrar audio (se conserva el texto)", role: .destructive) {
                if let n = confirmNote {
                    store.deleteAudio(of: n)
                    store.update(n.id) { $0.audioState = "deleted" }
                }
            }
        }
    }
}

// MARK: - Copia cifrada (plan, Fase 4)

struct BackupView: View {
    @State private var password = ""
    @State private var includeAudio = true
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var importURL: URL?
    @State private var importPassword = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                SecureField("Contraseña (mín. 8 caracteres)", text: $password)
                Toggle("Incluir el audio", isOn: $includeAudio)
                Button("Crear copia cifrada") {
                    run {
                        exportURL = try Backup.export(password: password, includeAudio: includeAudio)
                    }
                }
                .disabled(password.count < 8 || busy)
            } header: { Text("Exportar") } footer: {
                Text("AES-256 con tu contraseña. Tú eliges dónde guardarla (Archivos, un disco, AirDrop). Sin la contraseña no se puede abrir: Eugenia no la guarda.")
            }
            Section("Restaurar") {
                Button("Elegir copia…") { importing = true }
                if importURL != nil {
                    SecureField("Contraseña de la copia", text: $importPassword)
                    Button("Restaurar") {
                        run {
                            let n = try Backup.restore(from: importURL!, password: importPassword)
                            message = String(localized: "Restauradas \(n) reuniones.")
                            importURL = nil
                        }
                    }
                    .disabled(importPassword.isEmpty || busy)
                }
            }
            if let message { Section { Text(message) } }
        }
        .navigationTitle("Copia cifrada")
        .overlay { if busy { ProgressView() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { importURL = url }
        }
        .sheet(item: Binding(get: { exportURL.map { IdentifiedURL(url: $0) } }, set: { exportURL = $0?.url })) {
            ShareSheet(items: [$0.url])
        }
    }

    private func run(_ work: @escaping () throws -> Void) {
        busy = true
        message = nil
        // En la siguiente vuelta del bucle: deja pintar el indicador antes del PBKDF2.
        DispatchQueue.main.async {
            defer { busy = false }
            do { try work() } catch {
                message = (error as? CustomStringConvertible)?.description ?? Recorder.userMessage(for: error)
            }
        }
    }
}

struct IdentifiedURL: Identifiable { let url: URL; var id: String { url.path } }

// MARK: - Automatización (plan 5.8)

struct AutomationView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Permitir enviar reuniones fuera del iPhone", isOn: $settings.dataOutConsent)
            } footer: {
                Text("Sin este permiso, Eugenia no ejecuta ningún atajo de envío. Cuando lo das, lo que salga y adónde lo decide TU atajo, con tus credenciales. Eugenia no ve ese destino.")
            }
            if settings.dataOutConsent {
                Section {
                    TextField("Nombre exacto del atajo", text: $settings.crmShortcutName)
                        .textInputAutocapitalization(.never)
                } header: { Text("Atajo para «Enviar al CRM»") } footer: {
                    Text("Aparece como botón en el aviso de «Resumen listo» y en el menú de cada reunión.")
                }
            }
            Section("Ejemplo de atajo") {
                Text("""
                1. Obtener última reunión (Eugenia)
                2. Exportar reunión → formato JSON (Eugenia)
                3. Obtener contenido de URL → POST a tu webhook (Zapier, n8n, Make o el tuyo)
                4. Mostrar notificación «Enviado»
                """).font(.callout.monospaced())
                Text("El JSON sigue el esquema «eugenia.note/1»: título, fecha, resumen, decisiones, tareas con responsable, estado e instante, y la transcripción con hablantes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.dataOutConsent {
                Section { Label("Envío de datos activado", systemImage: "arrow.up.forward.circle.fill").foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Atajos y CRM")
    }
}

// MARK: - Textos legales (plan 12)

struct LegalView: View {
    enum Kind { case privacy, terms, recording }
    let kind: Kind

    var body: some View {
        ScrollView {
            Text(text).padding().frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
    }

    private var title: String {
        switch kind {
        case .privacy: return String(localized: "Privacidad")
        case .terms: return String(localized: "Condiciones de uso")
        case .recording: return String(localized: "Grabar a otras personas")
        }
    }

    private var text: String {
        switch kind {
        case .privacy:
            return String(localized: """
            Eugenia procesa tus reuniones exclusivamente en este iPhone.

            • El audio, las transcripciones, los resúmenes y las huellas de voz se guardan solo en el dispositivo, cifrados por iOS, y no se incluyen en las copias de seguridad de iCloud.
            • La transcripción usa los modelos de voz de iOS y el resumen, Apple Intelligence en el dispositivo. Eugenia no usa Private Cloud Compute ni ningún servidor propio o de terceros.
            • Eugenia se conecta a internet solo para descargar modelos (los de voz de iOS y los de separación de hablantes). No envía nada de tus reuniones.
            • No hay cuentas, analítica ni publicidad.
            • Los datos solo salen del iPhone si tú lo haces: compartiendo una exportación, creando una copia cifrada o activando el envío por Atajos.
            • Puedes borrar cualquier reunión, su audio o todas las huellas de voz en cualquier momento.
            """)
        case .terms:
            return String(localized: """
            Eugenia es una herramienta personal de uso privado. Se ofrece tal cual, sin garantías. Las transcripciones y los resúmenes se generan automáticamente y pueden contener errores: revisa lo importante contra el audio, que es la referencia.

            Eres responsable de cumplir la ley aplicable al grabar conversaciones y de obtener el consentimiento que corresponda.
            """)
        case .recording:
            return String(localized: """
            Antes de grabar una reunión, informa a los asistentes y, cuando la ley lo exija, obtén su consentimiento.

            • En España, grabar una conversación en la que participas es lícito, pero difundirla puede no serlo; los datos de terceros están protegidos por el RGPD.
            • En México, la grabación de comunicaciones privadas por un participante es generalmente lícita, pero su uso y difusión tienen límites legales.
            • En otros países puede exigirse el consentimiento de todas las partes.

            Eugenia muestra un indicador de grabación en todo momento y te lo recuerda al empezar. Las huellas de voz son datos biométricos: actívalas solo con el consentimiento de las personas afectadas.
            """)
        }
    }
}
