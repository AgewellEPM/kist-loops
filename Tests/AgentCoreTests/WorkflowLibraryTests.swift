import XCTest
@testable import AgentCore

final class WorkflowLibraryTests: XCTestCase {

    func testCatalogListsTheBusinessFlows() {
        let c = WorkflowLibrary.catalog()
        for name in ["data-report", "compare-data", "security-review", "media-brief", "research"] {
            XCTAssertTrue(c.contains(name), "catalog missing \(name)")
        }
    }

    func testFindIsCaseInsensitive() {
        XCTAssertEqual(WorkflowLibrary.find("Data-Report")?.name, "data-report")
        XCTAssertNil(WorkflowLibrary.find("nope"))
    }

    func testExpandSubstitutesInput() {
        let t = WorkflowLibrary.find("data-report")!
        let expanded = t.expand(input: "sales.xlsx")
        XCTAssertTrue(expanded.contains("sales.xlsx"))
        XCTAssertFalse(expanded.contains("{input}"))
    }

    func testExpandHandlesEmptyInputGracefully() {
        let expanded = WorkflowLibrary.find("research")!.expand(input: "")
        XCTAssertFalse(expanded.contains("{input}"))
        XCTAssertTrue(expanded.contains("the target the user named"))
    }

    func testEveryTemplateNamesRealTools() {
        // Each template's toolsUsed should reference tools that actually exist in the runtime.
        let known: Set<String> = ["read_spreadsheet", "query_data", "analyze_media", "extract_clip",
                                  "security_audit", "web_search", "fetch_url", "write_file", "read_file"]
        for t in WorkflowLibrary.templates {
            for tool in t.toolsUsed { XCTAssertTrue(known.contains(tool), "\(t.name) references unknown tool \(tool)") }
        }
    }
}
