import XCTest
@testable import AgentCore

final class LexicalSearchTests: XCTestCase {
    func testWholeQueryBeatsRepeatedSingleTerm() {
        let documents = [
            LexicalSearch.Document(id: "noise", title: "notes", text: String(repeating: "provider ", count: 2_000)),
            LexicalSearch.Document(id: "evidence", title: "RunReplayStore.swift", text: "Record every provider attempt in replay.")
        ]
        XCTAssertEqual(LexicalSearch.rank(documents, query: "provider attempt replay", limit: 1).map(\.id), ["evidence"])
    }

    func testIdentifierBoundariesAndNaturalQuestions() {
        let documents = [LexicalSearch.Document(id: "target", title: "SharedMemory.swift",
                                               text: "func spawnAgentsWithSharedMemory() {}\nstruct HTTPRetryQueue {}")]
        for query in ["shared-memory", "shared_memory", "HTTPRetryQueue", "How do I spawn agents with shared memory?"] {
            XCTAssertEqual(LexicalSearch.rank(documents, query: query, limit: 1).map(\.id), ["target"], query)
        }
    }

    func testMissingCompoundSymbolDoesNotMatchItsCommonSuffix() {
        let documents = [LexicalSearch.Document(id: "other", title: "a.swift", text: "let alphaMarker = true")]
        XCTAssertTrue(LexicalSearch.rank(documents, query: "betaMarker", limit: 5).isEmpty)
        XCTAssertTrue(LexicalSearch.rank(documents, query: "the and how", limit: 5).isEmpty)
    }

    func testShortLanguageNamesAndPunctuationStayDistinct() {
        let documents = [
            LexicalSearch.Document(id: "c", title: "C", text: "compiler"),
            LexicalSearch.Document(id: "cpp", title: "C++", text: "compiler"),
            LexicalSearch.Document(id: "cs", title: "C#", text: "compiler"),
            LexicalSearch.Document(id: "go", title: "Go", text: "compiler")
        ]
        for (query, id) in [("C", "c"), ("C++", "cpp"), ("C#", "cs"), ("Go", "go")] {
            XCTAssertEqual(LexicalSearch.rank(documents, query: query, limit: 5).map(\.id), [id])
        }
    }

    func testExcerptLocatesEvidenceBeyondBoilerplateAndLongLinePrefix() {
        let text = String(repeating: "import Foundation\n", count: 100)
            + String(repeating: "padding ", count: 150) + "providerAttemptEvidence must survive cleanup"
        let excerpt = LexicalSearch.excerpt(text, query: "provider attempt evidence", maxCharacters: 120)
        XCTAssertTrue(excerpt.contains("providerAttemptEvidence"), excerpt)
        XCTAssertLessThanOrEqual(excerpt.count, 120)
    }

    func testExcerptHonorsSmallCallerBudgetsIncludingUnicodeAndMarkers() {
        let texts = ["short", "", " \n\t", "intro\nneedle is here\nlast",
                     String(repeating: "👩🏽‍💻 café ", count: 30) + "needle"]
        for text in texts {
            for limit in -2...45 {
                let result = LexicalSearch.excerpt(text, query: "needle", maxCharacters: limit)
                XCTAssertLessThanOrEqual(result.count, max(0, limit), "limit=\(limit), result=\(result)")
                if limit <= 0 { XCTAssertEqual(result, "") }
            }
        }
        XCTAssertEqual(LexicalSearch.excerpt("short", query: "short", maxCharacters: 5), "short")
    }

    func testExcerptPreservesCompleteFittingTextIncludingWhitespaceAndGraphemes() {
        let texts = ["", "   \n\t", "alpha\nbeta", "\nneedle\n", "e\u{301}\n猫",
                     "👩🏽‍💻\n🙂", "alpha\r\nbeta", "ab\u{2028}cd"]
        for text in texts {
            for limit in [max(1, text.count), text.count + 8] {
                let result = LexicalSearch.excerpt(text, query: "needle", maxCharacters: limit)
                XCTAssertEqual(Array(result.utf8), Array(text.utf8), "limit=\(limit), text=\(text.debugDescription)")
                XCTAssertLessThanOrEqual(result.count, limit)
            }
        }
    }

    func testSpecialistDiscoveryUsesCodeSearchMatching() throws {
        let root = NSTemporaryDirectory() + "specialist-search-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let registry = SpecialistRegistry(projectRoot: root, userDir: nil, claudeUserDir: nil)
        try registry.save(SpecialistDefinition(name: "memory", description: "Maintains shared memory", systemPrompt: "Inspect memory."))
        try registry.save(SpecialistDefinition(name: "go-helper", description: "Build Go programs", systemPrompt: "Inspect Go code."))
        XCTAssertEqual(registry.matching(goal: "shared-memory").map(\.name), ["memory"])
        XCTAssertEqual(registry.matching(goal: "Go").map(\.name), ["go-helper"])
    }
}
