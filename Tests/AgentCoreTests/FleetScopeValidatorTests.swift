import XCTest
@testable import AgentCore

/// The deterministic gate that turns the planner's PROPOSED per-step scopes into a trustworthy,
/// DISJOINT fleet lease: hallucinated paths dropped, colliding steps cleared to permissive (never a
/// shared non-empty lease), fail direction always toward permissive. Pure; no I/O.
final class FleetScopeValidatorTests: XCTestCase {

    private let dirs: Set<String> = ["", "Core", "Core/Captain", "Core/AI", "Views", "Views/Cockpit"]

    // MARK: ownedPrefix

    func testOwnedPrefixStripsWildcardsAndSlashes() {
        XCTAssertEqual(FleetScopeValidator.ownedPrefix("Core/Captain/*"), "Core/Captain")
        XCTAssertEqual(FleetScopeValidator.ownedPrefix("Core/*"), "Core")
        XCTAssertEqual(FleetScopeValidator.ownedPrefix("Core/Foo.swift"), "Core/Foo.swift")
        XCTAssertEqual(FleetScopeValidator.ownedPrefix("*"), "")
    }

    // MARK: isReal

    func testIsRealAcceptsKnownDirAndNewFilesUnderIt() {
        XCTAssertTrue(FleetScopeValidator.isReal("Core/Captain/*", knownDirs: dirs))
        XCTAssertTrue(FleetScopeValidator.isReal("Core/Captain/BrandNewFile.swift", knownDirs: dirs),
                      "a NEW file under a known dir is real (dir-prefix scoping)")
    }

    func testIsRealRejectsHallucinatedAndRootOwningScopes() {
        XCTAssertFalse(FleetScopeValidator.isReal("Nope/Ghost/*", knownDirs: dirs))
        XCTAssertFalse(FleetScopeValidator.isReal("*", knownDirs: dirs), "owning the whole repo is never valid")
        XCTAssertFalse(FleetScopeValidator.isReal("", knownDirs: dirs))
    }

    // MARK: overlaps

    func testOverlapsByComponentPrefixNotStringPrefix() {
        XCTAssertTrue(FleetScopeValidator.overlaps("Core/*", "Core/Captain/*"), "ancestor overlaps descendant")
        XCTAssertTrue(FleetScopeValidator.overlaps("Core/Captain/*", "Core/Captain/*"), "equal overlaps")
        XCTAssertFalse(FleetScopeValidator.overlaps("Core/Captain/*", "Core/AI/*"), "siblings are disjoint")
        XCTAssertFalse(FleetScopeValidator.overlaps("Core/Cap/*", "Core/Captain/*"),
                       "shared STRING prefix but different dirs ⇒ NOT overlap")
    }

    // MARK: validate — the whole contract

    func testCleanDisjointRealScopesPassUntouched() {
        let r = FleetScopeValidator.validate(
            scopesPerStep: [["Core/Captain/*"], ["Core/AI/*"], ["Views/Cockpit/*"]], knownDirs: dirs)
        XCTAssertTrue(r.clean)
        XCTAssertTrue(r.issues.isEmpty)
        XCTAssertEqual(r.scopesPerStep, [["Core/Captain/*"], ["Core/AI/*"], ["Views/Cockpit/*"]])
    }

    func testHallucinatedScopeIsDroppedNotKept() {
        let r = FleetScopeValidator.validate(
            scopesPerStep: [["Core/Captain/*", "Ghost/*"], ["Core/AI/*"]], knownDirs: dirs)
        XCTAssertEqual(r.scopesPerStep[0], ["Core/Captain/*"], "the ghost path is dropped")
        XCTAssertFalse(r.clean)
        XCTAssertTrue(r.issues.contains { $0.contains("Ghost") })
    }

    func testCollidingStepsAreBothClearedToPermissive() {
        let r = FleetScopeValidator.validate(
            scopesPerStep: [["Core/*"], ["Core/Captain/*"], ["Views/Cockpit/*"]], knownDirs: dirs)
        XCTAssertEqual(r.scopesPerStep[0], [], "colliding step cleared (permissive, never a shared lease)")
        XCTAssertEqual(r.scopesPerStep[1], [], "the other colliding step cleared too")
        XCTAssertEqual(r.scopesPerStep[2], ["Views/Cockpit/*"], "the disjoint step is untouched")
        XCTAssertFalse(r.clean)
        XCTAssertTrue(r.issues.contains { $0.contains("collision") })
    }

    func testNeverHandsTwoAgentsAnOverlappingNonEmptyLease() {
        let r = FleetScopeValidator.validate(
            scopesPerStep: [["Core/*"], ["Core/AI/*"], ["Views/*"]], knownDirs: dirs)
        let nonEmpty = r.scopesPerStep.enumerated().filter { !$0.element.isEmpty }
        for (i, a) in nonEmpty {
            for (j, b) in nonEmpty where j > i {
                for ga in a { for gb in b {
                    XCTAssertFalse(FleetScopeValidator.overlaps(ga, gb),
                                   "post-validation leases must be pairwise disjoint (\(ga) vs \(gb))")
                } }
            }
        }
    }

    func testEmptyScopesAreFineNoInventedViolations() {
        let r = FleetScopeValidator.validate(scopesPerStep: [[], []], knownDirs: dirs)
        XCTAssertTrue(r.clean)
        XCTAssertEqual(r.scopesPerStep, [[], []])
    }

    // MARK: canonicalization — output MUST match the FleetMatcher (== the foreman matcher)

    func testCanonicalScopeCoversExactFileAndDirSubtree() {
        XCTAssertEqual(Set(FleetScopeValidator.canonicalScope("Core/Captain", knownDirs: dirs)),
                       ["Core/Captain", "Core/Captain/*"], "a known dir → exact + subtree")
        XCTAssertEqual(FleetScopeValidator.canonicalScope("Core/Captain/*", knownDirs: dirs), ["Core/Captain/*"],
                       "an already-subtree glob is kept as-is")
        XCTAssertEqual(FleetScopeValidator.canonicalScope("Core/Foo.swift", knownDirs: dirs), ["Core/Foo.swift"],
                       "a FILE (dotted, not a known dir) owns ONLY itself — no spurious <file>/*")
    }

    func testDottedDirectoryStillGetsSubtreeViaKnownDirs() {
        let withAssets: Set<String> = ["", "Assets.xcassets"]
        XCTAssertEqual(Set(FleetScopeValidator.canonicalScope("Assets.xcassets", knownDirs: withAssets)),
                       ["Assets.xcassets", "Assets.xcassets/*"],
                       "a dotted KNOWN directory must still get its subtree (no false refusal)")
    }

    func testLeadingSlashIsNormalizedNotDroppedAsHallucinated() {
        let r = FleetScopeValidator.validate(scopesPerStep: [["/Core/*"]], knownDirs: dirs)
        XCTAssertEqual(r.scopesPerStep[0], ["Core/*"], "leading slash stripped; the scope is kept")
        XCTAssertTrue(r.clean)
    }

    func testCurrentDirPrefixIsStrippedTraversalIsNot() {
        XCTAssertEqual(FleetScopeValidator.normalize("./Core/*"), "Core/*")
        let kept = FleetScopeValidator.validate(scopesPerStep: [["./Core/*"]], knownDirs: dirs)
        XCTAssertEqual(kept.scopesPerStep[0], ["Core/*"])
        let traversal = FleetScopeValidator.validate(scopesPerStep: [["../secrets/*"]], knownDirs: dirs)
        XCTAssertEqual(traversal.scopesPerStep[0], [], "a traversal scope is dropped to permissive, never matched")
    }

    func testDoubleSlashIsNormalizedSoTheMatcherMatches() {
        let lease = FleetScopeValidator.canonicalScope("Core//Captain/*", knownDirs: dirs)
        XCTAssertEqual(lease, ["Core/Captain/*"], "repeated slashes collapsed to a clean path")
        XCTAssertTrue(lease.contains { FleetMatcher.matches(path: "Core/Captain/Foo.swift", glob: $0) },
                      "the normalized lease matches the agent's committed files")
    }

    // MARK: grammar gate — partial-component wildcards rejected

    func testIsCanonicalGrammarAcceptsOnlyExactOrSubtree() {
        XCTAssertTrue(FleetScopeValidator.isCanonicalGrammar("Core/Captain"))
        XCTAssertTrue(FleetScopeValidator.isCanonicalGrammar("Core/Captain/*"))
        XCTAssertFalse(FleetScopeValidator.isCanonicalGrammar("Core/Capt*"), "partial-component wildcard")
        XCTAssertFalse(FleetScopeValidator.isCanonicalGrammar("*Captain"), "leading wildcard")
        XCTAssertFalse(FleetScopeValidator.isCanonicalGrammar("Core/*/Foo"), "mid wildcard")
        XCTAssertFalse(FleetScopeValidator.isCanonicalGrammar("Core/**"), "double star")
    }

    func testMaskedCollisionViaPartialWildcardIsDroppedNotMissed() {
        let r = FleetScopeValidator.validate(
            scopesPerStep: [["Core/Capt*"], ["Core/Captain/*"]], knownDirs: dirs)
        XCTAssertEqual(r.scopesPerStep[0], [], "the partial-wildcard scope is dropped (malformed)")
        XCTAssertEqual(r.scopesPerStep[1], ["Core/Captain/*"], "the legit sibling stands")
        XCTAssertFalse(r.clean)
        XCTAssertTrue(r.issues.contains { $0.contains("malformed") })
    }

    func testNoWildcardDirScopeStillMatchesCommittedFilesUnderTheMatcher() {
        let r = FleetScopeValidator.validate(scopesPerStep: [["Core/Captain"]], knownDirs: dirs)
        let lease = r.scopesPerStep[0]
        XCTAssertTrue(lease.contains { FleetMatcher.matches(path: "Core/Captain/Foo.swift", glob: $0) },
                      "a no-wildcard dir scope must match files UNDER it (else the foreman falsely refuses)")
        XCTAssertTrue(lease.contains { FleetMatcher.matches(path: "Core/Captain/Sub/Deep.swift", glob: $0) },
                      "...including nested files")
        XCTAssertFalse(lease.contains { FleetMatcher.matches(path: "Views/Other.swift", glob: $0) },
                       "but NOT files outside the owned dir (the lease still has teeth)")
    }

    func testCanonicalLeaseDoesNotMatchSiblingWithSharedStringPrefix() {
        let r = FleetScopeValidator.validate(scopesPerStep: [["Core/Captain"]], knownDirs: dirs)
        let lease = r.scopesPerStep[0]
        XCTAssertFalse(lease.contains { FleetMatcher.matches(path: "Core/CaptainHelper.swift", glob: $0) },
                       "a shared string prefix must NOT be treated as in-scope")
    }

    func testFleetMatcherRejectsMalformedWildcardsDirectly() {
        XCTAssertFalse(FleetMatcher.matches(path: "Core/Captain/Foo.swift", glob: "*"),
                       "raw star is not a canonical lease")
        XCTAssertFalse(FleetMatcher.matches(path: "Core/Captain/Foo.swift", glob: "*.swift"),
                       "suffix wildcards are not canonical leases")
        XCTAssertFalse(FleetMatcher.matches(path: "Core/Captain/Foo.swift", glob: "Core/Capt*"),
                       "partial-component wildcards are not canonical leases")
        XCTAssertTrue(FleetMatcher.matches(path: "Core/Captain/Foo.swift", glob: "Core/Captain/*"))
        XCTAssertTrue(FleetMatcher.matches(path: "Core/Captain/Foo.swift", glob: "Core/Captain/Foo.swift"))
    }
}
