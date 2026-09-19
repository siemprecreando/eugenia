import CryptoKit
import XCTest
@testable import Eugenia

/// Pruebas de la lógica de la v0.2 que no depende del hardware.

final class ActionResolverTests: XCTestCase {

    /// El caso del spike 4b: el presupuesto se asigna a Marta, se reasigna a Javier y
    /// se aplaza. Tiene que salir UNA tarea, aplazada, de Javier, con su historial.
    func testReassignmentChainIsOneItem() {
        let mentions = [
            Mention(refId: "c1", text: "Cerrar el presupuesto", assignee: "Marta", status: "propuesto", atSeconds: 190),
            Mention(refId: "c1", text: "Cerrar el presupuesto", assignee: "Javier", status: "reasignado", atSeconds: 2_515),
            Mention(refId: "c1", text: "Cerrar el presupuesto", assignee: "Javier", status: "aplazado", atSeconds: 3_500)
        ]
        let items = ActionResolver.resolve(mentions)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].assignee, "Javier")
        XCTAssertEqual(items[0].status, "aplazado")
        XCTAssertFalse(items[0].isOpen, "aplazado no puede salir como próximo paso")
        XCTAssertTrue(items[0].history.contains { $0.contains("Reasignado de Marta a Javier") }, "\(items[0].history)")
        XCTAssertFalse(items[0].needsConfirmation)
    }

    func testOrderIsByInstantNotByArrival() {
        let items = ActionResolver.resolve([
            Mention(refId: "x", text: "Tarea", assignee: "B", status: "confirmado", atSeconds: 500),
            Mention(refId: "x", text: "Tarea", assignee: "A", status: "propuesto", atSeconds: 100)
        ])
        XCTAssertEqual(items.first?.assignee, "B", "la última decisión en el TIEMPO gana")
    }

    func testConfirmedThenProposedIsFlagged() {
        let items = ActionResolver.resolve([
            Mention(refId: "x", text: "Enviar oferta", assignee: "Ana", status: "confirmado", atSeconds: 100),
            Mention(refId: "x", text: "Enviar oferta", assignee: "Ana", status: "propuesto", atSeconds: 900)
        ])
        XCTAssertTrue(items[0].needsConfirmation)
    }

    func testTwoOwnersWithin30sIsFlagged() {
        let items = ActionResolver.resolve([
            Mention(refId: "x", text: "Llamar al cliente", assignee: "Ana", status: "propuesto", atSeconds: 100),
            Mention(refId: "x", text: "Llamar al cliente", assignee: "Luis", status: "propuesto", atSeconds: 115)
        ])
        XCTAssertTrue(items[0].needsConfirmation)
    }

    func testDifferentRefIdsStaySeparate() {
        let items = ActionResolver.resolve([
            Mention(refId: "a", text: "Uno", assignee: "", status: "propuesto", atSeconds: 1),
            Mention(refId: "b", text: "Dos", assignee: "", status: "propuesto", atSeconds: 2)
        ])
        XCTAssertEqual(items.count, 2)
    }

    func testCheckpointRoundTrip() throws {
        let m = [Mention(refId: "c1", text: "T", assignee: "A", status: "confirmado", dueText: "el viernes", atSeconds: 42)]
        let p = [Point(text: "Idea", atSeconds: 7)]
        let cp = Summarizer.encodeCheckpoint(hash: "h", notes: "n", mentions: m, points: p)
        let back = try XCTUnwrap(Summarizer.decodeCheckpoint(cp))
        XCTAssertEqual(back.mentions, m)
        XCTAssertEqual(back.points, p)
    }
}

final class SplitTests: XCTestCase {
    /// ASR sin puntuación: antes salía UN trozo enorme que desbordaba la ventana.
    func testTextWithoutPunctuationIsHardSplit() {
        let text = String(repeating: "palabra ", count: 3_000)       // 24.000 caracteres, sin puntos
        let chunks = Summarizer.split(text)
        XCTAssertGreaterThan(chunks.count, 5)
        for c in chunks { XCTAssertLessThanOrEqual(c.count, Summarizer.chunkChars) }
        XCTAssertEqual(chunks.joined(), text, "el troceado no puede alterar el texto")
    }

    func testQuestionAndExclamationAreSentenceEnds() {
        let text = String(repeating: "¿Lo cerramos hoy? ¡Sí! ", count: 400)
        let chunks = Summarizer.split(text)
        XCTAssertEqual(chunks.joined(), text)
        for c in chunks { XCTAssertLessThanOrEqual(c.count, Summarizer.chunkChars) }
    }

    func testTimedLinesUseSpeakerNames() {
        let segs = [TranscriptSegment(text: "Hola", start: 65, end: 66, speaker: "S1"),
                    TranscriptSegment(text: "pausa", start: 70, end: 70, isMarker: true)]
        let lines = Summarizer.timedLines(segments: segs, plain: "", speakerName: { $0 == "S1" ? "Marta" : nil })
        XCTAssertEqual(lines, ["[01:05] Marta: Hola"])
    }
}

final class SpeakerAlignerTests: XCTestCase {
    func testMostOverlapWins() {
        let segs = [TranscriptSegment(text: "a", start: 0, end: 4)]
        let turns = [SpeakerTurn(label: "S1", start: 0, end: 1), SpeakerTurn(label: "S2", start: 1, end: 4)]
        XCTAssertEqual(SpeakerAligner.assign(segments: segs, turns: turns).first?.speaker, "S2")
    }

    func testNearestWithinOneSecond() {
        let segs = [TranscriptSegment(text: "a", start: 10, end: 10.5)]
        let turns = [SpeakerTurn(label: "S1", start: 11, end: 12)]
        XCTAssertEqual(SpeakerAligner.assign(segments: segs, turns: turns).first?.speaker, "S1")
    }

    func testFarAwayStaysUnassigned() {
        let segs = [TranscriptSegment(text: "a", start: 10, end: 11)]
        let turns = [SpeakerTurn(label: "S1", start: 30, end: 40)]
        XCTAssertNil(SpeakerAligner.assign(segments: segs, turns: turns).first?.speaker)
    }

    func testMarkersAreUntouched() {
        let segs = [TranscriptSegment(text: "pausa", start: 1, end: 1, isMarker: true)]
        let turns = [SpeakerTurn(label: "S1", start: 0, end: 5)]
        XCTAssertNil(SpeakerAligner.assign(segments: segs, turns: turns).first?.speaker)
    }

    func testCosine() {
        XCTAssertEqual(VoiceprintStore.cosine([1, 0], [1, 0]), 1, accuracy: 0.0001)
        XCTAssertEqual(VoiceprintStore.cosine([1, 0], [0, 1]), 0, accuracy: 0.0001)
        XCTAssertEqual(VoiceprintStore.cosine([], []), 0)
    }
}

/// Un índice de la v0.1 tiene que seguir abriéndose. Si no, `Store.load` lo daría por
/// ilegible y el usuario vería la biblioteca vacía.
final class NoteCompatTests: XCTestCase {
    func testV01IndexDecodes() throws {
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111","title":"Vieja","createdAt":"2026-09-18T10:00:00Z",
          "duration":60,"language":"es","audioFileName":"x.m4a","transcript":"hola","summaryOverview":"",
          "decisions":[],"actionItems":[{"text":"t","assignee":"","status":"propuesto","atSeconds":3}],
          "state":"transcribed","failure":null}]
        """
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let notes = try d.decode([Note].self, from: Data(json.utf8))
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].state, NoteState.queued, "transcribed de la v0.1 = en cola")
        XCTAssertEqual(notes[0].allAudioFiles, ["x.m4a"])
        XCTAssertEqual(notes[0].template, "executive")
        XCTAssertFalse(notes[0].actionItems[0].done)
    }

    func testRenderedTranscriptWithSpeakers() {
        var n = Note(title: "t", language: "es", state: NoteState.summarized)
        n.segments = [TranscriptSegment(text: "Hola", start: 0, end: 1, speaker: "S1"),
                      TranscriptSegment(text: "¿Qué tal?", start: 1, end: 2, speaker: "S1"),
                      TranscriptSegment(text: "Bien", start: 2, end: 3, speaker: "S2")]
        n.speakerNames = ["S1": "Marta"]
        XCTAssertEqual(n.renderedTranscript(), "Marta: Hola\n¿Qué tal?\nHablante 2: Bien")
    }
}

final class SecurityTests: XCTestCase {
    func testDiagnosticsRejectsPaths() {
        XCTAssertTrue(DiagnosticsRunner.isSafeName("es-sala-2m.m4a"))
        for bad in ["../x.m4a", "a/b.m4a", "..", ".", "", "../../Library/Application Support/audio/x.m4a"] {
            XCTAssertFalse(DiagnosticsRunner.isSafeName(bad), bad)
        }
    }

    func testArchiveRoundTripAndWrongPassword() throws {
        let dir = FileManager.default.temporaryDirectory
        let audio = dir.appendingPathComponent("a-\(UUID().uuidString).m4a")
        try Data([1, 2, 3, 4]).write(to: audio)
        let out = dir.appendingPathComponent("t-\(UUID().uuidString).eugenia")
        try EncryptedArchive.write(to: out, password: "contraseña-larga", index: Data("[]".utf8),
                                   files: [("parte.m4a", audio)])
        var got: [String: Data] = [:]
        let index = try EncryptedArchive.read(from: out, password: "contraseña-larga") { got[$0] = $1 }
        XCTAssertEqual(index, Data("[]".utf8))
        XCTAssertEqual(got["audio/parte.m4a"], Data([1, 2, 3, 4]))
        XCTAssertThrowsError(try EncryptedArchive.read(from: out, password: "otra-contraseña") { _, _ in })
        XCTAssertThrowsError(try EncryptedArchive.write(to: out, password: "corta", index: Data(), files: []))
    }

    /// v2: cortar el final, quitar un registro o tocar un byte tiene que FALLAR, no
    /// restaurar a medias en silencio (revisión de seguridad 2026-09-18).
    func testArchiveDetectsTruncationAndTampering() throws {
        let dir = FileManager.default.temporaryDirectory
        let a = dir.appendingPathComponent("a-\(UUID().uuidString).m4a")
        let b = dir.appendingPathComponent("b-\(UUID().uuidString).m4a")
        try Data(repeating: 7, count: 100).write(to: a)
        try Data(repeating: 9, count: 100).write(to: b)
        let out = dir.appendingPathComponent("t-\(UUID().uuidString).eugenia")
        let pw = "contraseña-larga"
        try EncryptedArchive.write(to: out, password: pw, index: Data("[]".utf8), files: [("a.m4a", a), ("b.m4a", b)])
        let full = try Data(contentsOf: out)
        XCTAssertEqual(full.prefix(5), Data("EUGX2".utf8))

        func reads(_ d: Data) -> Bool {
            let f = dir.appendingPathComponent("m-\(UUID().uuidString).eugenia")
            try? d.write(to: f)
            return (try? EncryptedArchive.read(from: f, password: pw) { _, _ in }) != nil
        }
        XCTAssertTrue(reads(full))
        // Registro final entero fuera: 2 + 4 ("#end") + 8 + 12 + 4 + 16 = 46 bytes.
        XCTAssertFalse(reads(full.dropLast(46)), "sin el registro final no puede darse por buena")
        XCTAssertFalse(reads(full.dropLast(5)), "cortada a mitad de registro")
        var flipped = full
        flipped[flipped.count / 2] ^= 0xFF
        XCTAssertFalse(reads(flipped), "un byte cambiado")
        XCTAssertFalse(reads(full + Data([0, 1, 2])), "basura detrás del final")
    }

    /// Las copias v1 (EUGX1, 210.000 iteraciones) se siguen pudiendo restaurar.
    func testArchiveV1StillReadable() throws {
        let pw = "contraseña-larga"
        let salt = Data((0..<16).map { UInt8($0) })
        let key = EncryptedArchive.deriveKey(password: pw, salt: salt, iterations: EncryptedArchive.iterationsV1)
        func record(_ name: String, _ data: Data) throws -> Data {
            let n = Data(name.utf8)
            let sealed = try AES.GCM.seal(data, using: key, authenticating: n).combined!
            return withUnsafeBytes(of: UInt16(n.count).bigEndian) { Data($0) } + n
                + withUnsafeBytes(of: UInt64(sealed.count).bigEndian) { Data($0) } + sealed
        }
        let v1 = Data("EUGX1".utf8) + salt + (try record("notes.json", Data("[]".utf8)))
            + (try record("audio/x.m4a", Data([5, 5])))
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("v1-\(UUID().uuidString).eugenia")
        try v1.write(to: f)
        var got: [String: Data] = [:]
        XCTAssertEqual(try EncryptedArchive.read(from: f, password: pw) { got[$0] = $1 }, Data("[]".utf8))
        XCTAssertEqual(got["audio/x.m4a"], Data([5, 5]))
    }

    /// "ñ" escrita como un carácter o como n + tilde combinada: la misma contraseña.
    func testPasswordIsUnicodeNormalized() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("n-\(UUID().uuidString).eugenia")
        try EncryptedArchive.write(to: out, password: "contrase\u{00F1}a-larga", index: Data("[]".utf8), files: [])
        XCTAssertNoThrow(try EncryptedArchive.read(from: out, password: "contrasen\u{0303}a-larga") { _, _ in })
        XCTAssertThrowsError(try EncryptedArchive.write(to: out, password: "once-letras", index: Data(), files: []),
                             "11 caracteres no bastan")
    }

    /// Una copia ajena no puede colar en una nota el audio de OTRA nota.
    func testRestoredAudioMustBelongToItsNote() {
        let id = UUID()
        XCTAssertTrue(Backup.isOwnAudio("\(id.uuidString)-000.m4a", of: id))
        XCTAssertTrue(Backup.isOwnAudio("\(id.uuidString)-012.m4a", of: id))
        XCTAssertTrue(Backup.isOwnAudio("\(id.uuidString).m4a", of: id))
        XCTAssertFalse(Backup.isOwnAudio("\(UUID().uuidString)-000.m4a", of: id))
        XCTAssertFalse(Backup.isOwnAudio("../\(id.uuidString)-000.m4a", of: id))
        XCTAssertFalse(Backup.isOwnAudio("\(id.uuidString)-000.m4a.sh", of: id))
    }

    func testLanguageSetting() {
        XCTAssertEqual(Recorder.resolveLanguage(setting: "en", preferred: ["es-ES"]), "en")
        XCTAssertEqual(Recorder.resolveLanguage(setting: "auto", preferred: ["es-MX"]), "es")
    }
}

final class RetentionAndExportTests: XCTestCase {
    private func note(daysAgo: Double, state: String = NoteState.summarized, favorite: Bool = false) -> Note {
        var n = Note(title: "n", createdAt: Date().addingTimeInterval(-daysAgo * 86_400), language: "es", state: state)
        n.audioParts = ["p.m4a"]
        n.isFavorite = favorite
        return n
    }

    func testRetentionOnlyOldSummarizedNonFavorite() {
        let notes = [note(daysAgo: 40), note(daysAgo: 5), note(daysAgo: 40, favorite: true),
                     note(daysAgo: 40, state: NoteState.queued)]
        XCTAssertEqual(RetentionPolicy.candidates(notes, days: 30).count, 1)
        XCTAssertEqual(RetentionPolicy.candidates(notes, days: 0).count, 0, "0 = nunca")
    }

    /// "Al terminar de procesar": fuera el audio de lo ya procesado CON texto; nunca el
    /// de una favorita, uno en cola o uno sin transcripción (sería lo único que queda).
    func testRetentionAfterProcessing() {
        func n(_ state: String, text: String = "hola", favorite: Bool = false) -> Note {
            var x = note(daysAgo: 0, state: state, favorite: favorite)
            x.transcript = text
            return x
        }
        let notes = [n(NoteState.summarized), n(NoteState.failed), n(NoteState.queued),
                     n(NoteState.summarized, favorite: true), n(NoteState.summarized, text: "  ")]
        XCTAssertEqual(RetentionPolicy.candidates(notes, days: RetentionPolicy.afterProcessing).count, 2)
    }

    /// El JSON es el contrato con los atajos de los usuarios: estas claves no cambian.
    func testJSONSchemaIsStable() throws {
        var n = Note(title: "Comité", language: "es", state: NoteState.summarized)
        n.summaryOverview = "Resumen"
        n.actionItems = [StoredActionItem(text: "Hacer X", assignee: "Ana", status: "confirmado", atSeconds: 5)]
        n.segments = [TranscriptSegment(text: "Hola", start: 0, end: 1, speaker: "S1")]
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: NoteExporter.json(n)) as? [String: Any])
        XCTAssertEqual(obj["schema"] as? String, "eugenia.note/1")
        for key in ["id", "title", "date", "durationSeconds", "language", "summary", "keyPoints", "decisions",
                    "actionItems", "transcript", "speakers"] {
            XCTAssertNotNil(obj[key], "falta \(key)")
        }
        let item = try XCTUnwrap((obj["actionItems"] as? [[String: Any]])?.first)
        for key in ["text", "assignee", "status", "due", "done", "atSeconds", "history", "needsConfirmation"] {
            XCTAssertNotNil(item[key], "falta actionItems[].\(key)")
        }
    }

    func testMarkdownKeepsClosedItemsOutOfNextSteps() {
        var n = Note(title: "T", language: "es", state: NoteState.summarized)
        n.actionItems = [StoredActionItem(text: "Abierta", assignee: "", status: "confirmado", atSeconds: 1),
                         StoredActionItem(text: "Aplazada", assignee: "", status: "aplazado", atSeconds: 2)]
        let md = NoteExporter.markdown(n)
        XCTAssertTrue(md.contains("Abierta"))
        XCTAssertFalse(md.contains("Aplazada"), "lo aplazado no es un próximo paso (plan 5.4.5)")
    }

    func testPDFIsProduced() {
        var n = Note(title: "T", language: "es", state: NoteState.summarized)
        n.transcript = String(repeating: "Texto largo de la reunión. ", count: 800)
        let data = NoteExporter.pdf(n)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
    }
}

final class SearchTests: XCTestCase {
    func testTokenizeFoldsAccents() {
        XCTAssertEqual(SearchIndex.tokenize("¿Qué decidió Marta?"), ["que", "decidio", "marta"])
    }

    func testGlobalQuestions() {
        XCTAssertTrue(SearchIndex.isGlobalQuestion("¿De qué trató la reunión?"))
        XCTAssertFalse(SearchIndex.isGlobalQuestion("¿Qué dijo Marta de Acme?"))
    }

    @MainActor
    func testLexicalSearchFindsProperNoun() {
        var a = Note(title: "A", language: "es", state: NoteState.summarized)
        a.segments = [TranscriptSegment(text: "Hablamos del cliente Acme y del contrato", start: 42, end: 45)]
        var b = Note(title: "B", language: "es", state: NoteState.summarized)
        b.segments = [TranscriptSegment(text: "Otra cosa distinta", start: 0, end: 1)]
        let hits = SearchIndex.shared.search("Acme", in: [a, b], semantic: false)
        XCTAssertEqual(hits.first?.noteID, a.id)
        XCTAssertEqual(hits.first?.atSeconds ?? -1, 42, accuracy: 0.01)
    }
}

final class SpeakerNamingTests: XCTestCase {
    private func seg(_ speaker: String, _ text: String) -> TranscriptSegment {
        TranscriptSegment(text: text, start: 0, end: 1, speaker: speaker)
    }

    func testSelfIntroductionsInSpanishAndEnglish() {
        let found = SpeakerNaming.selfIntroductions([
            seg("S1", "Hola a todos, soy Marta y llevo el proyecto."),
            seg("S2", "Buenas, me llamo Juan Pablo, de ventas."),
            seg("S3", "Hi everyone, I'm Kevin from the Monterrey office.")
        ])
        XCTAssertEqual(found, ["S1": "Marta", "S2": "Juan Pablo", "S3": "Kevin"])
    }

    func testNoFalsePositives() {
        let found = SpeakerNaming.selfIntroductions([
            seg("S1", "Yo soy consciente de que vamos tarde."),        // minúscula: no es nombre
            seg("S2", "Soy de Monterrey y soy Responsable de compras."), // palabras vetadas
            seg("S3", "I'm going to share my screen.")
        ])
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testConflictingIntroductionsAreDropped() {
        // Dos hablantes dicen "soy Marta" (uno cita al otro): no se asigna a ninguno.
        let found = SpeakerNaming.selfIntroductions([
            seg("S1", "Soy Marta."), seg("S2", "Y dijo: soy Marta, la de compras."), seg("S3", "Soy Luis.")
        ])
        XCTAssertEqual(found, ["S3": "Luis"])
    }

    func testRenameReplacesWholeWordsOnly() {
        XCTAssertEqual(Store.replaceWord("Hablante 2", with: "Marta", in: "Hablante 2 cierra el presupuesto; Hablante 21 no."),
                       "Marta cierra el presupuesto; Hablante 21 no.")
        XCTAssertEqual(Store.replaceWord("Ana", with: "Luisa", in: "Ana y Mariana"), "Luisa y Mariana")
    }

    @MainActor
    func testRenameAndReassignInStore() throws {
        var n = Note(title: "t", language: "es", state: NoteState.summarized)
        n.segments = [seg("S1", "Hola"), seg("S2", "Adiós"), seg("S2", "Esto lo dijo otro")]
        n.summaryOverview = "Hablante 2 se despide."
        n.actionItems = [StoredActionItem(text: "Enviar informe", assignee: "Hablante 2", status: "confirmado", atSeconds: 1)]
        Store.shared.save(n)
        defer { Store.shared.delete(Store.shared.note(n.id)!) }

        Store.shared.renameSpeaker(noteID: n.id, label: "S2", to: "Marta")
        var got = try XCTUnwrap(Store.shared.note(n.id))
        XCTAssertEqual(got.displayName(forSpeaker: "S2"), "Marta")
        XCTAssertEqual(got.summaryOverview, "Marta se despide.")
        XCTAssertEqual(got.actionItems.first?.assignee, "Marta")

        let label = Store.shared.reassignSegment(noteID: n.id, segmentID: n.segments[2].id, to: nil, newName: "Luis")
        got = try XCTUnwrap(Store.shared.note(n.id))
        XCTAssertEqual(label, "S3")
        XCTAssertEqual(got.segments[2].speaker, "S3")
        XCTAssertEqual(got.displayName(forSpeaker: "S3"), "Luis")
        XCTAssertEqual(got.segments[1].speaker, "S2", "las demás frases no cambian")
    }
}
