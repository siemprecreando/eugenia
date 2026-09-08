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
        let runId = UUID().uuidString.prefix(8).lowercased()

        let suite: DiagnosticsSuite
        if let data = try? Data(contentsOf: requestURL) {
            suite = try JSONDecoder().decode(DiagnosticsSuite.self, from: data)
            try? FileManager.default.removeItem(at: requestURL)
        } else {
            suite = DiagnosticsSuite(suite: "smoke", cases: [])
        }
        Log.event(Log.diag, "suite.start", nil, "id=\(runId) suite=\(suite.suite) cases=\(suite.cases.count)")

        UIDevice.current.isBatteryMonitoringEnabled = true
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
            run: .init(id: String(runId),
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

        Log.event(Log.diag, "suite.done", nil,
                  "id=\(runId) passed=\(report.summary.passed) failed=\(report.summary.failed) skipped=\(report.summary.skipped)")
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
        let audioURL = Store.shared.diagnosticsDirectory
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent(c.audioFile)

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return .init(id: c.id, status: "skipped", metrics: [:], expected: c.expected,
                         artifacts: [], logWindow: .init(category: "diag", from: from, to: Date()),
                         message: "Falta el audio: \(c.audioFile). Empújalo por AFC a diagnostics/audio/.")
        }

        do {
            let locale = Locale(identifier: c.language == "en" ? "en-US" : "es-ES")
            try await Transcriber.prepareModel(for: locale)

            let t0 = Date()
            let text = try await transcribeFile(at: audioURL, locale: locale, caseId: c.id)
            let asrMs = Date().timeIntervalSince(t0) * 1000

            var metrics: [String: Double] = [
                "durationMs": asrMs,
                "chars": Double(text.count),
                "peakMemoryMB": Double(peakMemoryMB())
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
                    return .init(id: c.id, status: "skipped", metrics: metrics, expected: c.expected,
                                 artifacts: [artifactName],
                                 logWindow: .init(category: "diag", from: from, to: Date()),
                                 message: "LLM no disponible: \(Summarizer.availabilityDescription())")
                }
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
                         logWindow: .init(category: c.kind == "asr" ? "asr" : "summarize", from: from, to: Date()),
                         message: failures.isEmpty ? nil : failures.joined(separator: "; "))
        } catch {
            return .init(id: c.id, status: "error", metrics: [:], expected: c.expected,
                         artifacts: [], logWindow: .init(category: "diag", from: from, to: Date()),
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

        let source = try FileAudioSource(url: url, realtimeFactor: 0)
        let done = AsyncStream<Void>.makeStream()
        try source.start(onBuffer: { buffer in
            Task { await transcriber.feed(buffer) }
        }, onFinish: {
            done.continuation.finish()
        })

        for await _ in done.stream {}
        // Margen para que los `Task` de feed encolados terminen de entrar.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await transcriber.finish()

        return await collector.value.joined(separator: " ")
    }

    // MARK: - Utilidades

    /// WER clásico por distancia de edición sobre palabras.
    static func wer(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference), h = normalize(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
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

    private static func normalize(_ s: String) -> [String] {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func peakMemoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint) / 1_048_576
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
