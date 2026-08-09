import Testing
import Foundation
@testable import MaiCore

@Suite struct PIIRedactorTests {
    private let policy = PIIPolicy()

    @Test func findsStructuredContactData() {
        let text = "Email me at sato.kenji@example.co.jp or call 090-1234-5678."
        let spans = PIIDetector.spans(in: text, policy: policy)
        #expect(spans.contains { $0.kind == .email })
        #expect(spans.contains { $0.kind == .phone })
    }

    /// A long number is only a card if it passes the checksum, otherwise every order id
    /// and meeting code in the transcript would be redacted.
    @Test func cardsNeedTheChecksum() {
        #expect(PIIDetector.passesLuhn("4111 1111 1111 1111"))
        #expect(!PIIDetector.passesLuhn("1234 5678 9012 3456"))
        let spans = PIIDetector.spans(in: "Card 4111 1111 1111 1111 on file.", policy: policy)
        #expect(spans.contains { $0.kind == .creditCard })
    }

    /// A 12-digit id also parses as a phone number; the more specific reading has to win,
    /// which is why identifiers are detected before the system detector runs.
    @Test func governmentIDBeatsPhoneReading() {
        let spans = PIIDetector.spans(in: "My number is 1234 5678 9012.", policy: policy)
        #expect(spans.contains { $0.kind == .governmentID })
    }

    /// The most important negative case in this file. The system tagger labels both of
    /// these personal names; redacting them would strip the subject out of the entity and
    /// place cards, which is the app's core value.
    @Test func placeAndThingNamesSurvive() {
        let neutral = "What time does the Shinkansen leave for Osaka?"
        let r = PIIRedactor(policy: policy)
        #expect(r.redact(neutral) == neutral)
    }

    @Test func placeholdersAreStableAcrossLines() {
        let r = PIIRedactor(policy: policy)
        let first = r.redact("Sato said the budget is tight.")
        let second = r.redact("Sato will confirm tomorrow.")
        let token = PIIRedactor.token(kind: .person, index: 1)
        #expect(!first.contains("Sato"))
        #expect(first.contains(token))
        #expect(second.contains(token))
        // Round trip is exact, so the user never sees the placeholder.
        #expect(r.rehydrate(first) == "Sato said the budget is tight.")
        #expect(r.rehydrate("Ask \(token) about it.").contains("Sato"))
    }

    /// Known participants are matched exactly. This is what actually protects the people
    /// in the room: the system tagger finds neither name in this sentence on its own.
    @Test func knownParticipantsAreMatchedExactly() {
        let r = PIIRedactor(policy: policy)
        r.registerKnownName("Tanaka")
        r.registerKnownName("Suzuki")
        let out = r.redact("Tanaka met Suzuki.")
        #expect(!out.contains("Tanaka"))
        #expect(!out.contains("Suzuki"))
        #expect(r.rehydrate(out) == "Tanaka met Suzuki.")
    }

    @Test func roleLabelsAreNotIdentities() {
        let r = PIIRedactor(policy: policy)
        r.registerKnownName("You")
        r.registerKnownName("Speaker 2")
        #expect(r.redact("You and Speaker 2 agreed.") == "You and Speaker 2 agreed.")
    }

    @Test func latinNamesRespectWordBoundaries() {
        let r = PIIRedactor(policy: policy)
        r.registerKnownName("Ann")
        #expect(r.redact("The announcement is ready.") == "The announcement is ready.")
    }

    @Test func policyOffChangesNothing() {
        let r = PIIRedactor(policy: .off)
        #expect(r.redact("Sato said hello") == "Sato said hello")
        #expect(PIIDetector.spans(in: "call 090-1234-5678", policy: .off).isEmpty)
    }

    @Test func perKindSwitchesAreRespected() {
        let peopleOnly = PIIPolicy(redactPeople: true, redactContacts: false,
                                   redactIdentifiers: false, redactURLs: false)
        let spans = PIIDetector.spans(in: "call 090-1234-5678", policy: peopleOnly)
        #expect(!spans.contains { $0.kind == .phone })
    }

    @Test func placeholderLettersRunPastZ() {
        #expect(PIIRedactor.letter(1) == "A")
        #expect(PIIRedactor.letter(26) == "Z")
        #expect(PIIRedactor.letter(27) == "AA")
    }
}
