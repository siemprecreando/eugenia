import AVFoundation
import Foundation
import UIKit

/// Ejecutor de pruebas dentro de la app. Solo se compila en Debug.
/// Plan, sección 6.5.
///
/// DISPARO: no depende de que `dvt launch` sepa pasar argumentos, que es justo lo que
/// el spike 8 tiene que averiguar. El contrato es un fichero:
///
///   1. Linux empuja `Documents/diagnostics/run.json` por AFC.
///   2. Linux lanza la app.
///   3. La app ve el fichero al arrancar, ejecuta la suite y lo borra.
///   4. La app escribe `Documents/diagnostics/report-<id>.json`.
///   5. Linux hace polling de ese informe y se lo lleva.
///
/// Si además `dvt launch` admite `-EugeniaDiagnostics YES`, también funciona.
#if DEBUG
@MainActor
enum DiagnosticsRunner {

    static var isRequested: Bool {
        if UserDefaults.standard.bool(forKey: "EugeniaDiagnostics") { return true }
        return FileManager.default.fileExists(atPath: requestURL.path)
    }

    static var requestURL: URL {
        Store.shared.diagnosticsDirectory.appendingPathComponent("run.json")
    }

    static func runIfRequested() async {
        guard isRequested else { return }
        Log.event(Log.diag, "suite.detected")
        do {
            try await run()
        } catch {
            Log.failure(Log.diag, "suite.run", error)
        }
    }

    static func run() async throws {
        let started = Date()
        // El identificador lleva marca de tiempo delante, no solo un UUID. Con UUID
        // suelto los informes NO se ordenan cronológicamente por nombre, y el script
        // de Linux coge "el último" alfabéticamente: podía traerse un informe viejo y
        // dar por bueno un PASS de otra ejecución. Es el peor fallo posible en un
        // banco de pruebas — mentir en verde.
        let stamp = ReportStamp.string(from: started)
        let runId = "\(stamp)-\(UUID().uuidString.prefix(4).lowercased())"

        let suite: DiagnosticsSuite
        if let data = try? Data(contentsOf: requestURL) {
            suite = try JSONDecoder().decode(DiagnosticsSuite.self, from: data)
            try? FileManager.default.removeItem(at: requestURL)
        } else {
            suite = DiagnosticsSuite(suite: "smoke", cases: [])
        }
        Log.event(Log.diag, "suite.start", "id=\(runId) suite=\(suite.suite) cases=\(suite.cases.count)")

        UIDevice.current.isBatteryMonitoringEnabled = true
        // Recién activada, `batteryLevel` devuelve -1 durante un instante. Sin esta
        // espera el informe decía "batería -100%", que es ruido con pinta de dato.
        if UIDevice.current.batteryLevel < 0 {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let env = DiagnosticsReport.Env(
            appleIntelligence: Summarizer.isAvailable,
            modelAvailability: Summarizer.availabilityDescription(),
            thermalState: String(describing: ProcessInfo.processInfo.thermalState),
            batteryLevel: Double(UIDevice.current.batteryLevel),
            freeDiskMB: Store.shared.freeDiskMB()
        )

        var results: [DiagnosticsReport.Case] = []
        for c in suite.cases {
            results.append(await runCase(c))
        }

        // Caso "smoke": prueba el bucle entero sin depender de audio ni del LLM.
        // Es el que valida el spike 8 (plan, Fase 0).
        results.insert(smokeCase(started: started), at: 0)

        let report = DiagnosticsReport(
            run: .init(id: runId,
                       commit: Bundle.main.object(forInfoDictionaryKey: "EugeniaCommit") as? String ?? "unknown",
                       device: deviceModel(),
                       os: UIDevice.current.systemVersion,
                       startedAt: started,
                       finishedAt: Date()),
            env: env,
            cases: results,
            summary: .init(passed: results.filter { $0.status == "pass" }.count,
                           failed: results.filter { $0.status == "fail" || $0.status == "error" }.count,
                           skipped: results.filter { $0.status == "skipped" }.count)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = Store.shared.diagnosticsDirectory.appendingPathComponent("report-\(runId).json")
        try encoder.encode(report).write(to: url, options: .atomic)

        Log.event(Log.diag, "suite.done", "id=\(runId) passed=\(report.summary.passed) failed=\(report.summary.failed) skipped=\(report.summary.skipped)")
    }

    // MARK: - Casos

    private static func smokeCase(started: Date) -> DiagnosticsReport.Case {
        DiagnosticsReport.Case(
            id: "smoke/loop",
            status: "pass",
            metrics: ["startupMs": Date().timeIntervalSince(started) * 1000],
            expected: ["startupMs": .init(max: 10_000, min: nil)],
            artifacts: [],
            logWindow: .init(category: "diag", from: started, to: Date()),
            message: "La app arrancó, leyó la suite y escribió el informe. El bucle Linux↔iPhone funciona."
        )
    }

    private static func runCase(_ c: DiagnosticsSuite.Case) async -> DiagnosticsReport.Case {
        let from = Date()

        // Caso sin audio: la transcripción viene dada y solo se ejercita el resumen.
        if let transcript = c.transcript {
            return await runSummarizeOnly(c, transcript: transcript, from: from)
        }

        guard let audioName = c.audioFile else {
            return .init(id: c.id, status: "error", metrics: [:], expected: c.expected,
                         artifacts: [], logWindow: .init(category: "diag", from: from, to: Date()),
                         message: "El caso no trae ni audioFile ni transcript.")
        }

        let audioURL = Store.shared.diagnosticsDirectory
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent(audioName)

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return .init(id: c.id, status: "skipped", metrics: [:], expected: c.expected,
                         artifacts: [], logWindow: .init(category: "diag", from: from, to: Date()),
                         message: "Falta el audio: \(audioName). Empújalo por AFC a diagnostics/audio/.")
        }

        do {
            let locale = Locale(identifier: c.language == "en" ? "en-US" : "es-ES")
            try await Transcriber.prepareModel(for: locale)

            // El pico de memoria se MUESTREA durante el caso. La primera versión leía
            // la huella una sola vez al final y la llamaba "peak", que es justo el
            // número que no sirve para el riesgo R11: el jetsam ocurre en el máximo,
            // no en el valor con el que terminas.
            let sampler = MemorySampler()
            sampler.start()

            let t0 = Date()
            let text = try await transcribeFile(at: audioURL, locale: locale, caseId: c.id)
            let asrMs = Date().timeIntervalSince(t0) * 1000

            var metrics: [String: Double] = [
                "durationMs": asrMs,
                "chars": Double(text.count)
            ]

            if let reference = c.referenceTranscript {
                metrics["wer"] = wer(reference: reference, hypothesis: text)
            }

            // Guarda la transcripción para que Linux se la pueda traer.
            let artifactName = "\(c.id.replacingOccurrences(of: "/", with: "_"))-transcript.txt"
            let artifactURL = Store.shared.diagnosticsDirectory.appendingPathComponent(artifactName)
            try? text.write(to: artifactURL, atomically: true, encoding: .utf8)

            if c.kind == "pipeline" || c.kind == "summarize" {
                let t1 = Date()
                if Summarizer.isAvailable {
                    let summary = try await Summarizer.summarize(transcript: text, language: c.language)
                    metrics["summaryMs"] = Date().timeIntervalSince(t1) * 1000
                    metrics["actionItems"] = Double(summary.actionItems.count)
                } else {
                    metrics["peakMemoryMB"] = Double(sampler.stop())
                    return .init(id: c.id, status: "skipped", metrics: metrics, expected: c.expected,
                                 artifacts: [artifactName],
                                 logWindow: .init(category: "diag", from: from, to: Date()),
                                 message: "LLM no disponible: \(Summarizer.availabilityDescription())")
                }
            }

            metrics["peakMemoryMB"] = Double(sampler.stop())

            let failures = c.expected.compactMap { key, threshold -> String? in
                guard let value = metrics[key] else { return "sin métrica \(key)" }
                if let max = threshold.max, value > max { return "\(key)=\(value) > max \(max)" }
                if let min = threshold.min, value < min { return "\(key)=\(value) < min \(min)" }
                return nil
            }

            return .init(id: c.id,
                         status: failures.isEmpty ? "pass" : "fail",
                         metrics: metrics,
                         expected: c.expected,
                         artifacts: [artifactName],
                         logWindow: .init(category: c.kind == "asr" ? "asr" : "summarize", from: from, to: Date()),
                         message: failures.isEmpty ? nil : failures.joined(separator: "; "))
        } catch {
            return .init(id: c.id, status: "error", metrics: [:], expected: c.expected,
                         artifacts: [], logWindow: .init(category: "diag", from: from, to: Date()),
                         message: String(describing: error))
        }
    }

    /// Ejercita únicamente el resumidor sobre una transcripción dada.
    ///
    /// Es lo que permite medir el map-reduce y la resolución temporal (plan 5.4) en el
    /// simulador de CI, sin micrófono, sin audio y sin dispositivo. La calidad acústica
    /// sigue necesitando el iPhone; el razonamiento, no.
    private static func runSummarizeOnly(_ c: DiagnosticsSuite.Case,
                                         transcript: String,
                                         from: Date) async -> DiagnosticsReport.Case {
        guard Summarizer.isAvailable else {
            return .init(id: c.id, status: "skipped", metrics: [:], expected: c.expected,
                         artifacts: [], logWindow: .init(category: "summarize", from: from, to: Date()),
                         message: "LLM no disponible: \(Summarizer.availabilityDescription())")
        }
        let sampler = MemorySampler()
        sampler.start()
        do {
            let t0 = Date()
            let summary = try await Summarizer.summarize(transcript: transcript, language: c.language)
            let metrics: [String: Double] = [
                "summaryMs": Date().timeIntervalSince(t0) * 1000,
                "actionItems": Double(summary.actionItems.count),
                "decisions": Double(summary.decisions.count),
                "overviewChars": Double(summary.overview.count),
                "peakMemoryMB": Double(sampler.stop())
            ]

            // El resumen se guarda como artefacto para poder leerlo desde fuera: un
            // número de action items correcto no garantiza que sean los correctos.
            let artifactName = "\(c.id.replacingOccurrences(of: "/", with: "_"))-summary.json"
            if let data = try? JSONEncoder().encode(
                ["overview": summary.overview,
                 "decisions": summary.decisions.joined(separator: " | "),
                 "actionItems": summary.actionItems
                     .map { "[\($0.status)] \($0.text) · \($0.assignee) · t=\($0.atSeconds)" }
                     .joined(separator: " | ")]) {
                try? data.write(to: Store.shared.diagnosticsDirectory
                    .appendingPathComponent(artifactName), options: .atomic)
            }

            let failures = c.expected.compactMap { key, threshold -> String? in
                guard let value = metrics[key] else { return "sin métrica \(key)" }
                if let max = threshold.max, value > max { return "\(key)=\(value) > max \(max)" }
                if let min = threshold.min, value < min { return "\(key)=\(value) < min \(min)" }
                return nil
            }
            return .init(id: c.id,
                         status: failures.isEmpty ? "pass" : "fail",
                         metrics: metrics,
                         expected: c.expected,
                         artifacts: [artifactName],
                         logWindow: .init(category: "summarize", from: from, to: Date()),
                         message: failures.isEmpty ? nil : failures.joined(separator: "; "))
        } catch {
            _ = sampler.stop()
            return .init(id: c.id, status: "error", metrics: [:], expected: c.expected,
                         artifacts: [], logWindow: .init(category: "summarize", from: from, to: Date()),
                         message: String(describing: error))
        }
    }

    /// Transcribe un fichero completo usando el MISMO pipeline que el micrófono.
    /// Que sea el mismo camino es el punto: si aquí pasa, en vivo también.
    private static func transcribeFile(at url: URL, locale: Locale, caseId: String) async throws -> String {
        let transcriber = Transcriber()
        let segments = try await transcriber.start(locale: locale, caseId: caseId)

        // El consumidor arranca ANTES de alimentar: si se consume después de
        // finalizar el analizador, se depende del buffer del AsyncStream para no
        // perder segmentos. Mejor no depender de eso.
        let collector = Task<[String], Never> {
            var finals: [String] = []
            for await segment in segments where segment.isFinal {
                finals.append(segment.text)
            }
            return finals
        }

        // Mismo problema de orden que en Recorder: un `Task` por buffer no conserva
        // la secuencia. Aquí importa todavía más, porque las métricas de WER que
        // salgan de aquí son las que deciden la puerta de la Fase 0 — un desorden
        // silencioso las falsearía sin dar ningún error.
        let (buffers, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .unbounded
        )
        let pump = Task.detached(priority: .userInitiated) {
            for await buffer in buffers { await transcriber.feed(buffer) }
        }

        let source = try FileAudioSource(url: url, realtimeFactor: 0)
        let done = AsyncStream<Void>.makeStream()
        try source.start(onBuffer: { buffer in
            continuation.yield(buffer)
        }, onFinish: {
            done.continuation.finish()
        })

        for await _ in done.stream {}
        // Cerrar la cola y ESPERAR a que se drene, en vez de dormir un rato y confiar.
        // El `sleep` de la primera versión era una carrera: en una reunión larga o un
        // dispositivo caliente, 1,5 s no bastan y se perdía el final de la prueba.
        continuation.finish()
        await pump.value
        await transcriber.finish()

        return await collector.value.joined(separator: " ")
    }

    // MARK: - Utilidades

    /// WER clásico por distancia de edición sobre palabras.
    ///
    /// `nonisolated` porque es una función PURA: entra texto, sale un número, no toca
    /// estado ni interfaz. Heredaba el @MainActor del enum sin ninguna razón, y eso
    /// la hacía imposible de probar desde un test síncrono — además de obligar a un
    /// salto al hilo principal por cada caso, en mitad de una medición de tiempos.
    nonisolated static func wer(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference), h = normalize(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        // CRASH que encontró la prueba: con la hipótesis vacía, el bucle de abajo
        // hacía `for j in 1...0`, o sea un rango invertido, y eso es un fatal error
        // que se lleva la app por delante.
        //
        // Y no era un caso de laboratorio: la hipótesis vacía es exactamente lo que
        // devuelve el transcriptor cuando el ASR falla o el audio está en silencio.
        // Es decir, el banco de pruebas petaba justo en el fallo que existe para
        // medir. Sin transcripción, todo son borrados: el WER es 1.
        guard !h.isEmpty else { return 1 }
        var prev = Array(0...h.count)
        var cur = [Int](repeating: 0, count: h.count + 1)
        for i in 1...r.count {
            cur[0] = i
            for j in 1...h.count {
                let cost = r[i - 1] == h[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }

    nonisolated private static func normalize(_ s: String) -> [String] {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
#endif
