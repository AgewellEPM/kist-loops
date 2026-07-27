import XCTest
@testable import AgentCore

/// Pins the "Drop a Key, Drop a Doc" verdict: a model is only onboarded-ready when its REAL loop probe
/// passed (fail-closed), and the render surfaces the template + probe honestly.
final class ModelLoopVerifyTests: XCTestCase {

    private func probe(_ readiness: ModelLoopProbe.Readiness) -> ModelLoopProbe.Report {
        ModelLoopProbe.Report(providerId: "p", model: "m", usesNative: false,
                              path: .ok("p"), roundTrip: .ok("rt"), readiness: readiness)
    }

    func testReadyOnlyWhenProbeReady() {
        XCTAssertTrue(ModelLoopVerify.isReady(probe: probe(.ready), docError: nil))
        XCTAssertFalse(ModelLoopVerify.isReady(probe: probe(.partial), docError: nil))
        XCTAssertFalse(ModelLoopVerify.isReady(probe: probe(.broken), docError: nil))
    }

    func testUnreadableDocFailsClosedEvenWhenProbeReady() {
        // A dropped doc that can't be parsed is a HARD failure — never silently ignored.
        XCTAssertFalse(ModelLoopVerify.isReady(probe: probe(.ready), docError: "bad doc"))
        let r = ModelLoopVerify.Report(providerId: "local", model: "m", template: nil,
                                       docError: "could not read a chat template from 'x'",
                                       probe: probe(.ready), ready: false)
        let out = ModelLoopVerify.render(r)
        XCTAssertTrue(out.contains("NOT READY"))
        XCTAssertTrue(out.contains("✗ doc:"))
        XCTAssertTrue(out.contains("could not be read"))
    }

    func testRenderReadyWithTemplate() {
        let tpl = LocalModelTemplate.from(chatTemplate: "<|im_end|>", eosToken: nil,
                                          modelName: "qwen", source: "tokenizer_config.json")
        let r = ModelLoopVerify.Report(providerId: "local", model: "qwen2-7b", template: tpl,
                                       probe: probe(.ready), ready: true)
        let out = ModelLoopVerify.render(r)
        XCTAssertTrue(out.contains("READY TO USE"))
        XCTAssertTrue(out.contains("ChatML"))
        XCTAssertTrue(out.contains("<|im_end|>"))
        XCTAssertTrue(out.contains("local:qwen2-7b"))
    }

    func testRenderNotReadySurfacesCaveat() {
        let r = ModelLoopVerify.Report(providerId: "p", model: nil, template: nil,
                                       probe: probe(.partial), ready: false)
        let out = ModelLoopVerify.render(r)
        XCTAssertTrue(out.contains("NOT READY"))
        XCTAssertTrue(out.contains("caveats"))
    }

    func testRenderBrokenSaysNotUsable() {
        let r = ModelLoopVerify.Report(providerId: "p", model: nil, template: nil,
                                       probe: probe(.broken), ready: false)
        XCTAssertTrue(ModelLoopVerify.render(r).contains("not usable yet"))
    }
}
