import XCTest
@testable import Eugenia

/// Pruebas de la lógica que NO depende del hardware. Corren en el simulador, sin
/// teléfono y sin Apple Intelligence. Plan, sección 6.5.
final class WERTests: XCTestCase {

    func testIdenticalIsZero() {
        XCTAssertEqual(DiagnosticsRunner.wer(reference: "hola qué tal estás",
                                             hypothesis: "hola qué tal estás"), 0, accuracy: 0.0001)
    }

    func testOneSubstitutionInFourWords() {
        // 1 error / 4 palabras de referencia = 0,25
        XCTAssertEqual(DiagnosticsRunner.wer(reference: "hola qué tal estás",
                                             hypothesis: "hola qué tal estoy"), 0.25, accuracy: 0.0001)
    }

    func testEmptyHypothesisIsTotalError() {
        XCTAssertEqual(DiagnosticsRunner.wer(reference: "una dos tres",
                                             hypothesis: ""), 1.0, accuracy: 0.0001)
    }

    /// El WER debe ignorar tildes, mayúsculas y puntuación: si no, mediría el
    /// formateo del transcriptor en vez de su acierto, y los números de la Fase 0
    /// saldrían inflados por un motivo que no importa.
    func testIgnoresAccentsCaseAndPunctuation() {
        XCTAssertEqual(DiagnosticsRunner.wer(reference: "Sí, vendrá mañana.",
                                             hypothesis: "si vendra manana"), 0, accuracy: 0.0001)
    }

    func testInsertionCounts() {
        // "una dos tres" vs "una dos y tres": una inserción sobre 3 palabras
        XCTAssertEqual(DiagnosticsRunner.wer(reference: "una dos tres",
                                             hypothesis: "una dos y tres"), 1.0/3.0, accuracy: 0.0001)
    }
}

final class SummarizerSplitTests: XCTestCase {

    func testShortTextIsOneChunk() {
        XCTAssertEqual(Summarizer.split("Una reunión corta.").count, 1)
    }

    func testEmptyTextIsNoChunks() {
        XCTAssertTrue(Summarizer.split("").isEmpty)
    }

    /// Ningún fragmento puede pasarse mucho del límite: si se pasa, la llamada al
    /// modelo desborda la ventana de 4.096 tokens y el resumen falla en silencio.
    func testLongTextIsSplitAndNoChunkIsHuge() {
        let sentence = "Marta se encarga del presupuesto para el viernes. "
        let long = String(repeating: sentence, count: 400)   // ~20.000 caracteres
        let chunks = Summarizer.split(long)

        XCTAssertGreaterThan(chunks.count, 1, "un texto de 20k caracteres debe trocearse")
        for chunk in chunks {
            XCTAssertLessThan(chunk.count, 4_000, "fragmento demasiado grande: \(chunk.count)")
        }
    }

    /// Trocear no puede perder texto. Es la propiedad que de verdad importa.
    func testSplitPreservesContent() {
        let long = String(repeating: "Javier revisa el informe. ", count: 300)
        let joined = Summarizer.split(long).joined()
        XCTAssertEqual(joined.filter { !$0.isWhitespace }.count,
                       long.filter { !$0.isWhitespace }.count,
                       "el troceado perdió o duplicó caracteres")
    }
}

final class ReportContractTests: XCTestCase {

    /// El informe es el contrato con scripts/devtest.sh. Si cambian los nombres de
    /// los campos, el script deja de entender los resultados — y como los lee un
    /// proceso distinto, en otra máquina, nadie se entera hasta que falla.
    func testReportRoundTripAndFieldNames() throws {
        let now = Date()
        let report = DiagnosticsReport(
            run: .init(id: "20260908-120000-abcd", commit: "deadbeef", device: "iPhone17,5",
                       os: "26.6", startedAt: now, finishedAt: now),
            env: .init(appleIntelligence: false, modelAvailability: "unavailable(x)",
                       thermalState: "nominal", batteryLevel: -1, freeDiskMB: 1234),
            cases: [.init(id: "asr/es/x", status: "fail",
                          metrics: ["wer": 0.14],
                          expected: ["wer": .init(max: 0.08, min: nil)],
                          artifacts: ["a.txt"],
                          logWindow: .init(category: "asr", from: now, to: now),
                          message: "wer=0.14 > max 0.08")],
            summary: .init(passed: 0, failed: 1, skipped: 0))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Exactamente las claves que lee devtest.sh
        for key in ["run", "env", "cases", "summary"] {
            XCTAssertNotNil(json[key], "falta la clave de nivel superior '\(key)'")
        }
        let env = try XCTUnwrap(json["env"] as? [String: Any])
        for key in ["modelAvailability", "thermalState", "batteryLevel", "freeDiskMB"] {
            XCTAssertNotNil(env[key], "falta env.\(key)")
        }
        let first = try XCTUnwrap((json["cases"] as? [[String: Any]])?.first)
        for key in ["id", "status", "metrics", "expected", "artifacts", "logWindow"] {
            XCTAssertNotNil(first[key], "falta cases[].\(key)")
        }
        let expected = try XCTUnwrap(first["expected"] as? [String: Any])
        let wer = try XCTUnwrap(expected["wer"] as? [String: Any])
        XCTAssertNotNil(wer["max"], "el umbral debe viajar dentro del informe")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(DiagnosticsReport.self, from: data)
        XCTAssertEqual(back.summary.failed, 1)
        XCTAssertEqual(back.cases.first?.metrics["wer"] ?? 0, 0.14, accuracy: 0.0001)
    }

    /// La marca de tiempo va en el NOMBRE de un fichero que además viaja por AFC.
    /// Un ':' ahí es problema seguro, y además tiene que ordenar cronológicamente.
    func testReportStampIsFilenameSafeAndSortable() {
        let early = ReportStamp.string(from: Date(timeIntervalSince1970: 1_000_000))
        let late  = ReportStamp.string(from: Date(timeIntervalSince1970: 2_000_000))

        for bad in [":", "/", " ", "\\"] {
            XCTAssertFalse(early.contains(bad), "la marca contiene '\(bad)'")
        }
        XCTAssertLessThan(early, late, "ordenar por nombre debe ser ordenar por fecha")
    }
}

final class BacklogTests: XCTestCase {

    /// decrement() devuelve la profundidad ANTES de descontar: es la que decide si
    /// el ASR se salta un buffer. Si devolviera la de después, el freno de presión
    /// actuaría un buffer tarde.
    func testDecrementReturnsDepthBeforeDecreasing() {
        let backlog = Backlog()
        backlog.increment()
        backlog.increment()
        XCTAssertEqual(backlog.decrement(), 2)
        XCTAssertEqual(backlog.decrement(), 1)
    }

    func testNeverGoesNegative() {
        let backlog = Backlog()
        XCTAssertEqual(backlog.decrement(), 0)
        XCTAssertEqual(backlog.decrement(), 0)
    }
}
