import Foundation

enum BuilderGovernedWorkerIdentity {
    static func validate<ID: Equatable>(actual: ID, expected: ID) throws {
        guard actual == expected else {
            throw BuilderGovernedWorkerIdentityError(
                expected: String(describing: expected),
                actual: String(describing: actual)
            )
        }
    }
}

struct BuilderGovernedWorkerIdentityError: LocalizedError, Equatable {
    let expected: String
    let actual: String

    var errorDescription: String? {
        "governed worker node mismatch: expected \(expected), received \(actual)"
    }
}
