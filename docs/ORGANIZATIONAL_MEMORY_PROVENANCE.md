# Organizational recall provenance

Organizational recall carries the original `MemoryTemporalEnvelope` from each source through
`CaptainMemoryCandidate` and the Kist host adapter to `AgentMemoryEntry`. Rules, explicit
knowledge debt, capsules, specialist evidence, all four generic shelves, and scorecard summaries
are covered. Legacy typed records project their recorded event clocks in memory; undated generic
rows and unindexed research artifacts remain raw audit data.

`host_projected_lesson` is host-project only and requires a complete envelope. A provenance label,
upstream filtering, or a bare observation timestamp cannot substitute for that envelope. The
admission gate independently evaluates the supplied lifecycle, validity, decay and explicit season
at the recall clock. All admissions remain advisory; the envelope is temporal metadata, not an
authenticated completion receipt. The adapter retains its existing host-project restriction because
legacy organizational readers do not guarantee confined reads through every path component.

Scorecard summaries use the oldest included observation as their evidence anchor and expire when
that observation leaves the existing 30-day scorecard window. The newest observation is retained as
the aggregate transaction clock. A later read rebuilds the summary from surviving observations;
reading does not refresh the captured summary or rewrite its source rows.

The store is split into its core, `OrganizationalLearningStore+Retrieval.swift`, and
`OrganizationalLearningStore+Persistence.swift`. Persistence limits, locking, legacy decoding and
mutation refusals are preserved by the extraction. This change does not alter stored JSONL schemas;
`CaptainMemoryCandidate` adds an optional Codable field so old candidates still decode, with no
invented temporal identity.

Regression coverage lives in `OrganizationalMemoryEnvelopeTests` and `MemoryAdmissionGateTests`,
with the existing organizational, scorecard, temporal and shared-memory suites covering the split.
These are source changes. Installed behavior requires a separate sanctioned Kist promotion.
