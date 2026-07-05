import Testing
@testable import MaiCore

@Suite struct ConfigTests {
    @Test func defaultHardCapIsThreeSeconds() {
        #expect(Config().hardCapSeconds == 3)
    }

    @Test func tomlKeepsHashInsideQuotedStrings() {
        let parsed = TOML.parse("""
        [models]
        screen = "gemini#experiment" # trailing comment
        classifier = 'claude#haiku'
        """)

        #expect(parsed["models"]?["screen"]?.string == "gemini#experiment")
        #expect(parsed["models"]?["classifier"]?.string == "claude#haiku")
    }

    @Test func loadSessionRolloverSettings() throws {
        let dir = maiTempDir()
        let url = dir.appendingPathComponent("config.toml")
        try """
        [session]
        auto_rollover = false
        idle_rollover_seconds = 300
        max_seconds = 7200
        """.write(to: url, atomically: true, encoding: .utf8)

        let config = Config.load(path: url.path)

        #expect(config.sessionAutoRollover == false)
        #expect(config.sessionIdleRolloverSeconds == 300)
        #expect(config.sessionMaxSeconds == 7200)
    }
}
