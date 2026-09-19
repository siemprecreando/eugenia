import SwiftUI

/// Primer arranque (plan, Fase 1: permisos progresivos y descarga de modelos). Los
/// modelos de voz se piden AQUÍ y no en mitad de la primera reunión (plan 5.2).
struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var page = 0
    @State private var micGranted: Bool?
    @State private var modelsState: String?
    @State private var notificationsGranted: Bool?
    @State private var understood = false

    var body: some View {
        VStack {
            TabView(selection: $page) {
                step(icon: "lock.shield", title: "Tus reuniones no salen de tu iPhone",
                     text: "Eugenia graba, transcribe, separa hablantes y resume sin servidores. Compruébalo: funciona en modo avión.") {
                    EmptyView()
                }.tag(0)

                step(icon: "mic.fill", title: "Micrófono",
                     text: "Para grabar hace falta el micrófono. La grabación sigue con la pantalla bloqueada.") {
                    permissionButton(granted: micGranted, label: "Permitir el micrófono") {
                        micGranted = await MicrophoneAudioSource.requestPermission()
                    }
                }.tag(1)

                step(icon: "arrow.down.circle", title: "Modelos de voz",
                     text: "iOS descarga una vez los modelos de voz en español e inglés. Mejor ahora, con Wi-Fi, que al empezar la primera reunión.") {
                    VStack(spacing: 8) {
                        if let modelsState { Text(modelsState).font(.callout) }
                        Button("Descargar ahora") {
                            Task {
                                modelsState = String(localized: "Descargando…")
                                do {
                                    try await Transcriber.prepareModel(for: Locale(identifier: "es-ES"))
                                    try await Transcriber.prepareModel(for: Locale(identifier: "en-US"))
                                    modelsState = String(localized: "Listo")
                                } catch {
                                    modelsState = Recorder.userMessage(for: error)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }.tag(2)

                step(icon: "sparkles", title: "Apple Intelligence",
                     text: Summarizer.isAvailable
                        ? "Disponible: los resúmenes se harán en este iPhone."
                        : "Para los resúmenes, activa Apple Intelligence en Ajustes › Apple Intelligence y Siri. Mientras tanto Eugenia graba y transcribe con normalidad, y resumirá lo pendiente cuando lo actives.") {
                    EmptyView()
                }.tag(3)

                step(icon: "bell", title: "Avisos",
                     text: "Un aviso cuando el resumen esté listo. Solo muestra el título de la reunión, nunca su contenido.") {
                    permissionButton(granted: notificationsGranted, label: "Permitir avisos") {
                        notificationsGranted = await Notifier.requestPermission()
                    }
                }.tag(4)

                step(icon: "person.2.wave.2", title: "Graba con respeto",
                     text: "Avisa a los asistentes antes de grabar y, cuando la ley lo exija, pide su consentimiento. Eugenia muestra siempre que está grabando.") {
                    Toggle("Entendido", isOn: $understood).padding(.horizontal, 40)
                        .accessibilityIdentifier("onboarding-understood")
                }.tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 5 { withAnimation { page += 1 } } else { settings.onboardingDone = true }
            } label: {
                Text(page < 5 ? "Siguiente" : "Empezar").frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(page == 5 && !understood)
            .padding()
            .accessibilityIdentifier("onboarding-next")
        }
    }

    private func step<Extra: View>(icon: String, title: LocalizedStringKey, text: String,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: icon).font(.system(size: 64)).foregroundStyle(.tint)
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text(LocalizedStringKey(text)).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 28)
            extra()
            Spacer()
        }
    }

    private func permissionButton(granted: Bool?, label: LocalizedStringKey, action: @escaping () async -> Void) -> some View {
        Group {
            switch granted {
            case .some(true): Label("Permitido", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .some(false): Text("Denegado. Puedes cambiarlo en Ajustes › Eugenia.").font(.callout).foregroundStyle(.orange)
            case .none: Button(label) { Task { await action() } }.buttonStyle(.bordered)
            }
        }
    }
}
