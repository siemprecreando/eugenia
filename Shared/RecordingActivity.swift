import ActivityKit
import AppIntents
import Foundation

/// Compartido entre la app y la extensión de widgets (Live Activity, Dynamic Island y
/// el control del Centro de Control). Plan 5.1 y Fase 4.
///
/// NADA de contenido de la reunión aquí: la Live Activity se ve con el teléfono
/// bloqueado. Solo título, tiempo y nivel.
struct RecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Instante "virtual" de inicio: ahora − tiempo grabado. Permite que el
        /// temporizador del sistema cuente solo sin actualizar cada segundo.
        var timerStart: Date
        var level: Double
        var interrupted: Bool
    }
    var title: String
}

/// Grabar desde el Centro de Control, el botón de Acción o Siri. Abre la app: grabar
/// exige la sesión de audio en primer plano.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Grabar reunión"
    static let description = IntentDescription("Empieza a grabar una reunión en Eugenia.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Título")
    var meetingTitle: String?

    init() {}
    init(title: String?) { self.meetingTitle = title }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !EUGENIA_WIDGET
        AppRouter.shared.startRecording(title: meetingTitle)
        #endif
        return .result()
    }
}

/// Parar desde la Live Activity o la Dynamic Island sin abrir la app.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Detener grabación"
    static let description = IntentDescription("Detiene la grabación en curso y la guarda.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !EUGENIA_WIDGET
        await Recorder.shared.stop()
        #endif
        return .result()
    }
}
