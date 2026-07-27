import XCTest
@testable import AgentCore

/// Structural symbol extraction + the symbols tool (outline / find). Covers the pure
/// per-language extractor, file outline, repo-wide definition search, confinement, and
/// registration as a read-only tool.
final class SymbolsToolTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "symbols-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }
    private func ctx() -> ToolContext { ToolContext(projectRoot: root, shell: .denied) }
    private func write(_ rel: String, _ body: String) throws {
        let full = root + "/" + rel
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try body.write(toFile: full, atomically: true, encoding: .utf8)
    }

    // MARK: - pure extractor

    func testSwiftOutline() {
        let src = "import Foundation\npublic struct Foo {\n    func bar() {}\n    private func baz(x: Int) -> Int { x }\n}\nenum E { case a }\n"
        let syms = SymbolExtractor.outline(src, language: "swift")
        XCTAssertTrue(syms.contains { $0.kind == "type" && $0.name == "Foo" && $0.line == 2 })
        XCTAssertTrue(syms.contains { $0.kind == "func" && $0.name == "bar" })
        XCTAssertTrue(syms.contains { $0.kind == "func" && $0.name == "baz" })
        XCTAssertTrue(syms.contains { $0.kind == "type" && $0.name == "E" })
    }

    func testTypeScriptOutline() {
        let src = "export class Widget {}\nexport function build(x) {}\nconst make = (a: number) => a + 1\ninterface Shape {}\n"
        let syms = SymbolExtractor.outline(src, language: "ts")
        XCTAssertTrue(syms.contains { $0.name == "Widget" && $0.kind == "type" })
        XCTAssertTrue(syms.contains { $0.name == "build" && $0.kind == "func" })
        XCTAssertTrue(syms.contains { $0.name == "make" && $0.kind == "func" })
        XCTAssertTrue(syms.contains { $0.name == "Shape" })
    }

    func testPythonRustGoOutline() {
        XCTAssertTrue(SymbolExtractor.outline("class A:\n    def m(self): pass\n", language: "python").contains { $0.name == "m" && $0.kind == "func" })
        XCTAssertTrue(SymbolExtractor.outline("pub fn run() {}\nstruct S;\nimpl S {}\n", language: "rust").contains { $0.name == "run" && $0.kind == "func" })
        XCTAssertTrue(SymbolExtractor.outline("func (s *S) Do() {}\ntype T struct{}\n", language: "go").contains { $0.name == "Do" && $0.kind == "func" })
    }

    func testLanguageDetection() {
        XCTAssertEqual(SymbolExtractor.language(forPath: "a/b.swift"), "swift")
        XCTAssertEqual(SymbolExtractor.language(forPath: "x.tsx"), "ts")
        XCTAssertNil(SymbolExtractor.language(forPath: "README.md"))
    }

    func testUnknownLanguageIsEmptyNotCrash() {
        XCTAssertTrue(SymbolExtractor.outline("whatever\n", language: "cobol").isEmpty)
    }

    func testAllPatternsCompile() {
        // No checked-in pattern may silently fail to compile (Codex LOW).
        for (lang, pats) in SymbolExtractor.patterns {
            for p in pats {
                XCTAssertNoThrow(try NSRegularExpression(pattern: p.regex), "\(lang)/\(p.kind) must compile")
            }
        }
    }

    func testTypeScriptTypedAndSingleParamArrows() {
        // Codex MED: typed var + single-param arrows were missed.
        let src = "const f: Handler = (x) => x\nconst g = y => y + 1\n"
        let syms = SymbolExtractor.outline(src, language: "ts")
        XCTAssertTrue(syms.contains { $0.name == "f" && $0.kind == "func" }, "typed arrow must be found")
        XCTAssertTrue(syms.contains { $0.name == "g" && $0.kind == "func" }, "single-param arrow must be found")
    }

    func testJavaMethodsFoundControlFlowNot() {
        // Codex MED: Java methods were not extracted. Control flow must NOT be captured.
        let src = "public class C {\n    public void run() {}\n    private int add(int a) { return a; }\n    if (x) {\n    for (int i=0;i<3;i++) {\n}\n"
        let syms = SymbolExtractor.outline(src, language: "java")
        XCTAssertTrue(syms.contains { $0.name == "run" && $0.kind == "func" })
        XCTAssertTrue(syms.contains { $0.name == "add" && $0.kind == "func" })
        XCTAssertFalse(syms.contains { $0.name == "x" || $0.name == "i" }, "control flow must not be mistaken for methods")
    }

    func testCppFunctionsFoundControlFlowNot() {
        // Codex MED: C/C++ functions were not extracted. Control flow must NOT be captured.
        let src = "int main() {\n    if (a) {\n    while (b) {\n    return 0;\n}\n"
        let syms = SymbolExtractor.outline(src, language: "cpp")
        XCTAssertTrue(syms.contains { $0.name == "main" && $0.kind == "func" })
        XCTAssertFalse(syms.contains { $0.name == "a" || $0.name == "b" }, "if/while must not be mistaken for functions")
    }

    func testLimitClamped() {
        XCTAssertEqual(SymbolsTool().clampedLimit(nil), 200)
        XCTAssertEqual(SymbolsTool().clampedLimit(0), 1)
        XCTAssertEqual(SymbolsTool().clampedLimit(9_999_999), SymbolsTool.maxLimit)
    }

    // MARK: - tool: outline

    func testOutlineToolLinesAndKinds() async throws {
        try write("Sources/App.swift", "struct App {\n    func run() {}\n}\n")
        let r = try await SymbolsTool().execute(arguments: ["action": "outline", "path": "Sources/App.swift"], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("type App"))
        XCTAssertTrue(r.output.contains("func run"))
        XCTAssertEqual(r.metadata["count"], "2")
    }

    func testOutlineUnsupportedTypeFails() async throws {
        try write("notes.md", "# hi\n")
        let r = try await SymbolsTool().execute(arguments: ["action": "outline", "path": "notes.md"], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error?.contains("unsupported file type"), true)
    }

    // MARK: - tool: find

    func testFindLocatesDefinitionAcrossRepo() async throws {
        try write("Sources/A.swift", "func alpha() {}\n")
        try write("Sources/sub/B.swift", "struct Beta {}\nfunc alpha() {}\n")   // alpha defined twice
        let r = try await SymbolsTool().execute(arguments: ["action": "find", "name": "alpha"], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("Sources/A.swift:1"))
        XCTAssertTrue(r.output.contains("Sources/sub/B.swift:2"))
        XCTAssertEqual(r.metadata["matches"], "2", "find must locate EVERY definition site")
    }

    func testFindExactVsContains() async throws {
        try write("S.swift", "struct FileStore {}\nstruct MemStore {}\n")
        let exact = try await SymbolsTool().execute(arguments: ["action": "find", "name": "FileStore"], context: ctx())
        XCTAssertEqual(exact.metadata["matches"], "1")
        let contains = try await SymbolsTool().execute(arguments: ["action": "find", "name": "Store", "contains": true], context: ctx())
        XCTAssertEqual(contains.metadata["matches"], "2")
    }

    func testFindPathEscapeRefused() async throws {
        do {
            _ = try await SymbolsTool().execute(arguments: ["action": "find", "name": "x", "path": "../escape"], context: ctx())
            XCTFail("expected pathEscape")
        } catch let e as ToolError {
            guard case .pathEscape = e else { return XCTFail("expected pathEscape, got \(e)") }
        }
    }

    // MARK: - registration

    func testRegisteredReadOnly() {
        XCTAssertTrue(ToolRegistry.headless().all().contains { $0.name == "symbols" })
        XCTAssertTrue(HeadlessAgentLoop.readOnlyTools.contains("symbols"))
    }
}
