import XCTest
@testable import Kist

final class KistSMLRuntimeServeOptionTests: XCTestCase {
    func testServeFlagsAreBoundedAndMutuallyExclusive() {
        let serve = KistOptions.parse([
            "--sml-runtime-serve", "graphs/review.langgraph.json",
            "--sml-port", "8850",
        ])
        XCTAssertEqual(serve.smlRuntimeServe, "graphs/review.langgraph.json")
        XCTAssertEqual(serve.smlRuntimeServePort, 8_850)
        XCTAssertTrue(serve.optionErrors.isEmpty)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-serve <json>"))

        let missingSource = KistOptions.parse(["--sml-runtime-serve"])
        XCTAssertNil(missingSource.smlRuntimeServe)
        XCTAssertTrue(missingSource.optionErrors.contains {
            $0.contains("--sml-runtime-serve requires <source.json>")
        })

        for invalidPort in ["0", "1023", "65536", "not-a-port"] {
            let invalid = KistOptions.parse([
                "--sml-runtime-serve", "graphs/review.langgraph.json",
                "--sml-port", invalidPort,
            ])
            XCTAssertNil(invalid.smlRuntimeServePort)
            XCTAssertTrue(invalid.optionErrors.contains {
                $0.contains("--sml-port requires a port number >= 1024")
            })
        }

        let portWithoutServe = KistOptions.parse(["--sml-port", "8850"])
        XCTAssertTrue(portWithoutServe.optionErrors.contains {
            $0.contains("--sml-port requires --sml-runtime-serve")
        })

        let conflictingMode = KistOptions.parse([
            "--sml-runtime-serve", "graphs/review.langgraph.json",
            "--sml-runtime-api", "graphs/review.langgraph.json",
            "--sml-path", "/source/runtime/catalog",
        ])
        XCTAssertTrue(conflictingMode.optionErrors.contains {
            $0.contains("--sml-runtime-serve conflicts with --sml-runtime-api")
        })
    }
}
