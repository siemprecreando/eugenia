import Foundation
import SwiftUI

/// Preferencias del usuario. `UserDefaults` y nada más: son pocas, no son sensibles
/// (ninguna guarda contenido de reuniones) y así las ven igual la app y los intents.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard

    /// auto | es | en
    @Published var recordingLanguage: String { didSet { d.set(recordingLanguage, forKey: "recordingLanguage") } }
    /// room | speakerCall | dictation
    @Published var micProfile: String { didSet { d.set(micProfile, forKey: "micProfile") } }
    @Published var keepScreenOn: Bool { didSet { d.set(keepScreenOn, forKey: "keepScreenOn") } }
    /// Días tras los que se borra el AUDIO de una reunión ya resumida. 0 = nunca.
    /// La transcripción y el resumen no se borran nunca solos (plan 8.2).
    @Published var audioRetentionDays: Int { didSet { d.set(audioRetentionDays, forKey: "audioRetentionDays") } }
    @Published var defaultTemplate: String { didSet { d.set(defaultTemplate, forKey: "defaultTemplate") } }
    /// neutral | formal | casual | concise
    @Published var summaryTone: String { didSet { d.set(summaryTone, forKey: "summaryTone") } }
    @Published var faceIDLock: Bool { didSet { d.set(faceIDLock, forKey: "faceIDLock") } }
    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    /// Consentimiento para que datos de una reunión salgan del teléfono por un atajo
    /// (plan 5.8). Sin él, "Enviar al CRM" no ejecuta nada.
    @Published var dataOutConsent: Bool { didSet { d.set(dataOutConsent, forKey: "dataOutConsent") } }
    /// Nombre del atajo de Atajos que se ejecuta con "Enviar al CRM".
    @Published var crmShortcutName: String { didSet { d.set(crmShortcutName, forKey: "crmShortcutName") } }
    @Published var calendarSuggestions: Bool { didSet { d.set(calendarSuggestions, forKey: "calendarSuggestions") } }
    @Published var voiceprintsEnabled: Bool { didSet { d.set(voiceprintsEnabled, forKey: "voiceprintsEnabled") } }
    @Published var diarizationEnabled: Bool { didSet { d.set(diarizationEnabled, forKey: "diarizationEnabled") } }

    private init() {
        recordingLanguage = d.string(forKey: "recordingLanguage") ?? "auto"
        micProfile = d.string(forKey: "micProfile") ?? MicProfile.room.rawValue
        keepScreenOn = d.object(forKey: "keepScreenOn") as? Bool ?? false
        audioRetentionDays = d.object(forKey: "audioRetentionDays") as? Int ?? 0
        defaultTemplate = d.string(forKey: "defaultTemplate") ?? SummaryTemplate.executive.rawValue
        summaryTone = d.string(forKey: "summaryTone") ?? "neutral"
        faceIDLock = d.object(forKey: "faceIDLock") as? Bool ?? false
        let args = ProcessInfo.processInfo.arguments
        // Pruebas de interfaz: sin onboarding salvo que la prueba lo pida.
        if args.contains("--show-onboarding") {
            onboardingDone = false
        } else {
            onboardingDone = (d.object(forKey: "onboardingDone") as? Bool ?? false)
                || args.contains("--ui-demo") || args.contains("--skip-onboarding")
        }
        dataOutConsent = d.object(forKey: "dataOutConsent") as? Bool ?? false
        crmShortcutName = d.string(forKey: "crmShortcutName") ?? ""
        calendarSuggestions = d.object(forKey: "calendarSuggestions") as? Bool ?? false
        voiceprintsEnabled = d.object(forKey: "voiceprintsEnabled") as? Bool ?? false
        diarizationEnabled = d.object(forKey: "diarizationEnabled") as? Bool ?? true
    }
}
