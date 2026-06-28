import Foundation
@testable import MaiCore

// Shared test scaffolding. Everything runs with StubLLM + StubPlaces and a temp
// SQLite file, so `swift test` makes zero live calls.

func maiTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mai-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

struct TestRig {
    let engine: Engine
    let face: ConsoleFace
    let store: SQLiteStore
    let dir: URL
}

func makeRig(_ config: Config = Config(), llm: LLMProvider = StubLLM(), places: PlacesProvider = StubPlaces()) throws -> TestRig {
    let dir = maiTempDir()
    let store = try SQLiteStore(path: dir.appendingPathComponent("mai.sqlite").path)
    let verbatim = VerbatimLog(directory: dir.path, filename: "verbatim.jsonl")
    let face = ConsoleFace()
    let location = FixedLocation(lat: config.testLat, lng: config.testLng)
    let engine = Engine(config: config, llm: llm, places: places, location: location,
                        store: store, verbatim: verbatim, face: face)
    return TestRig(engine: engine, face: face, store: store, dir: dir)
}

func tline(_ text: String, speaker: String? = nil) -> EngineInput {
    .transcript(TranscriptEvent(text: text, speaker: speaker, timestamp: Date(), isFinal: true))
}
func sscreen(_ content: String) -> EngineInput {
    .screen(ScreenContentEvent(content: content, timestamp: Date(), isChange: true))
}
