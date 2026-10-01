import XCTest
import AgentCore
@testable import Kist

final class KistSMLRuntimeStartupOrderingTests: XCTestCase {
    func testRuntimeExportAndREPLDispatchBeforeProviderRegistryStartup() throws {
        let source = kistRunnerFamilySource(entryPointFirst: true)
        let apiDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeAPI != nil"))
        let launchDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeLaunch != nil"))
        let openAPIDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeOpenAPI != nil"))
        let modelRouterDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeModelRouter != nil"))
        let onyxDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeOnyx != nil"))
        let planningDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimePlanning != nil"))
        let catalogDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeCatalog != nil"))
        let mountDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeMount != nil"))
        let agentGuideDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeAgentGuide != nil"))
        let hostGuideDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeHostGuide != nil"))
        let hostWiringDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeHostWiring != nil"))
        let runbookDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeRunbook != nil"))
        let scaffoldDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeScaffold != nil"))
        let attachmentsDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeAttachments != nil"))
        let serveDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeServe != nil"))
        let replScriptDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeREPLScript != nil"))
        let replDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeREPL != nil"))
        let apiScriptDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeAPIScript != nil"))
        let exportDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeExport != nil"))
        let modelDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeModel != nil"))
        let modelScriptDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeModelScript != nil"))
        let configLoad = try XCTUnwrap(source.range(of: "let config = KistConfig.load()"))
        let buildTools = try XCTUnwrap(source.range(of: "let extraTools = Self.buildExtraTools"))

        XCTAssertLessThan(
            apiDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime API must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            openAPIDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime OpenAPI export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            modelRouterDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime model-router export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            onyxDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime Onyx export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            planningDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime planning export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            catalogDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime catalog export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            mountDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime mount export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            agentGuideDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime agent guide export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            hostGuideDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime host guide export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            hostWiringDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime host wiring export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            runbookDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime runbook export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            scaffoldDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime scaffold export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            launchDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime launch descriptor must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            attachmentsDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime attachments must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            serveDispatch.lowerBound,
            configLoad.lowerBound,
            "SML runtime serve must own its bounded headless driver registry"
        )
        XCTAssertLessThan(
            replScriptDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime REPL script must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            apiScriptDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime API script must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            replDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime REPL must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            exportDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertGreaterThan(
            modelDispatch.lowerBound,
            configLoad.lowerBound,
            "SML runtime model mode intentionally resolves a real provider/model before execution"
        )
        XCTAssertGreaterThan(
            modelScriptDispatch.lowerBound,
            configLoad.lowerBound,
            "SML runtime model-script mode intentionally resolves a real provider/model before execution"
        )
        XCTAssertLessThan(
            modelDispatch.lowerBound,
            buildTools.lowerBound,
            "SML runtime model mode must use the generated model-router tool, not the normal agent tool registry"
        )
        XCTAssertLessThan(
            modelScriptDispatch.lowerBound,
            buildTools.lowerBound,
            "SML runtime model-script mode must use the generated model-router tool, not the normal agent tool registry"
        )

        let workflowPathOverrideForwardCount = source.components(
            separatedBy: "apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides"
        ).count - 1
        let runtimeLaunchCount = source.components(
            separatedBy: "withSMLRuntimeHostLaunch("
        ).count - 1
        XCTAssertEqual(
            workflowPathOverrideForwardCount,
            runtimeLaunchCount,
            "every SML runtime CLI mode must forward --sml-api-workflow-path into the runtime launch helpers"
        )
    }

}
