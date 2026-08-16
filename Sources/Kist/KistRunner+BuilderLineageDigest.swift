import AgentCore

extension KistRunner {
    /// Builder contracts require a cryptographic digest even though older research artifacts
    /// retain their legacy report digest for durable PEEL replay compatibility.
    static func builderResearchDossierDigest(_ dossier: AutonomyMissionDossier) -> String {
        BuilderEvidenceDigest.sha256(dossier.text)
    }
}
