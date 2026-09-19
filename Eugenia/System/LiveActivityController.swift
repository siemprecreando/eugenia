import ActivityKit
import Foundation

/// Live Activity de la grabación en curso (plan 5.1 y Fase 4): temporizador, nivel y
/// botón de parar en la pantalla bloqueada y la Dynamic Island.
///
/// Las actualizaciones tienen presupuesto: se limitan a una cada 5 s o a los cambios
/// de estado (interrupción). El temporizador lo cuenta el sistema solo.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<RecordingAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastInterrupted = false

    func start(noteID: UUID, title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let state = RecordingAttributes.ContentState(timerStart: Date(), level: 0, interrupted: false)
        do {
            activity = try Activity.request(attributes: RecordingAttributes(title: title),
                                            content: .init(state: state, staleDate: nil))
        } catch {
            // Sin Live Activity se graba igual: es un extra, no un requisito.
            Log.failure(Log.system, "liveactivity.start", error)
        }
    }

    func update(elapsed: Double, level: Float, interrupted: Bool) {
        guard let activity else { return }
        let changed = interrupted != lastInterrupted
        guard changed || Date().timeIntervalSince(lastUpdate) >= 5 else { return }
        lastUpdate = Date()
        lastInterrupted = interrupted
        let state = RecordingAttributes.ContentState(timerStart: Date().addingTimeInterval(-elapsed),
                                                     level: Double(level), interrupted: interrupted)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
