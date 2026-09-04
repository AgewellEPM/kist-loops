# SML Runtime Operator Guide

The SML runtime is an approval-gated local harness. It can import reviewed OpenAPI operations,
mount them as exact HTTP capabilities, and run the generated wrapper workflows through the same
durable claim, approval, evidence, and replay protections as built-in tools.

This surface is pilot-ready. It is designed around explicit approval, least privilege, bounded
inputs, and auditable evidence, but it is not an OpenAI certification and it is not a public or
multi-tenant service boundary.

## 1. Import an OpenAPI document

The source must be an OpenAPI 3.0 or 3.1 JSON file inside the project root. YAML, external `$ref`
targets, operations without `operationId`, remote plain HTTP, query/cookie API keys, and unsupported
schema shapes fail closed.

```bash
.build/release/kist \
  --project /path/to/project \
  --sml-import-openapi specs/service.openapi.json \
  --sml-api-id service
```

`--sml-api-id` is optional when a safe identifier can be derived from the filename. `--sml-out`
may place the generated tree in another project-confined directory for review.

The importer publishes create-only, owner-only (`0600`) artifacts. Re-importing identical bytes is
safe; a different artifact at the same path is never overwritten. The source-set index is published
last so an interrupted import cannot expose a runnable index with missing workflows.

Without `--sml-out`, the generated files are:

- `.kist/sml/http-endpoints/service.json`: secret-free, pinned endpoint specifications.
- `.kist/sml/proposals/service.catalog.proposed.json`: the exact capability names proposed for
  admission.
- `.kist/sml/http-workflows/service.<operationId>.workflow.json`: one wrapper per operation; the
  durable loader applies the approval policy before validation and execution.
- `.kist/sml/http-workflows/service.sources.json`: the runtime source set to launch.

The command prints a manifest with source and artifact digests. It does not create credentials and
does not modify `.kist/sml/catalog.json`.

## 2. Review and admit capabilities

Review the original API document, the pinned servers, every generated endpoint, and the proposed
capability list. Copy only explicitly approved names into the live host catalog's
`tool_capabilities`; never replace the catalog blindly with the proposal.

Minimal catalog for one imported operation:

```json
{
  "schema_version": 1,
  "tool_capabilities": ["service.inventory.get"],
  "approval_authorities": ["host-operator"]
}
```

An endpoint capability absent from the catalog has no execution authority. At launch, the HTTP
driver is constructed only for the intersection of validated endpoint bundles and the
human-reviewed catalog. A catalog name grants the endpoint currently loaded under that exact name,
so revoke and re-review the grant before intentionally replacing a bundle. A capability collision
with a built-in driver aborts the launch.

The durable host also requires `.kist/sml/authority.json`. Grant the runtime actor only the command
operations and approval authorities it needs. Keep this file owner-only:

```bash
chmod 600 .kist/sml/authority.json .kist/sml/catalog.json
```

The default policy gates every externally advanced instruction. An absent `.kist/sml/policy.json`
means `approve_always`; do not add a relaxation unless the host owner has reviewed its effect.

## 3. Add host-only credentials

Write `.kist/sml/http-auth.json` yourself and set mode `0600`. This path is covered by the
repository's `.kist/` ignore rule; still treat it as a secret and never commit or paste it into a
workflow, endpoint bundle, catalog, prompt, or approval message.

```json
{
  "schema_version": 1,
  "credentials": {
    "service.apiKey": {"value": "replace-with-api-key"},
    "service.basic": {"username": "replace-user", "password": "replace-password"},
    "service.oauth": {"value": "replace-access-token", "scopes": ["inventory:read"]}
  }
}
```

```bash
chmod 600 .kist/sml/http-auth.json
```

Credential IDs and required scopes come from the import manifest and endpoint bundle. The host
must provide one complete OpenAPI security alternative. Credentials are loaded once at startup
through a descriptor-confined, no-symlink, owner-only read. They are excluded from generated
artifacts, errors, and durable evidence. API-key and bearer values must be visible ASCII; basic-auth
usernames and passwords may be Unicode but cannot contain control characters.

## 4. Run through the durable approval gate

Use the generated source set with the durable REPL:

```bash
.build/release/kist \
  --project /path/to/project \
  --sml-runtime-repl .kist/sml/http-workflows/service.sources.json \
  --sml-runtime-durable
```

Or start the long-lived loopback harness:

```bash
.build/release/kist \
  --project /path/to/project \
  --sml-runtime-serve .kist/sml/http-workflows/service.sources.json
```

Serve mode binds only to loopback and writes a per-session bearer token at
`.kist/sml/serve/session-token`. Do not proxy or expose it as a public endpoint. Use the generated
workflow commands/routes to start a task, inspect its pending gate and exact revision, then approve
that revision. A stale approval loses with a conflict instead of approving newer work.

Every outbound operation is parked before dispatch. After approval, the host durably claims the
step before sending bytes. A timeout, cancellation, connection loss, oversized response, or
unprovable response to a non-read method leaves an uncertain claim for human reconciliation; the
runtime never automatically retries it. A completed claim is not replayed after a drain or restart.

## Network and data limits

- Remote endpoints require HTTPS. Plain HTTP is accepted only for literal `127.0.0.1` or `::1`,
  which supports fully local/offline services.
- Imported origins are exact and pinned. Workflows can select only a reviewed server index; they
  cannot supply a URL or host.
- Redirects, cookies, URL caching, ambient proxy and credential storage, and query/cookie API keys
  are disabled or refused.
- OpenAPI source and endpoint bundles are capped at 8 MiB. Request JSON defaults to 1 MiB and can
  be declared up to 4 MiB. URL and aggregate headers are capped at 64 KiB each.
- Response bodies are capped at 64 KiB because the current workflow state stores the response as
  one bounded string. Larger responses require a future artifact-backed response path.
- Operation timeout defaults to 30 seconds and may be declared only within 0.1...60 seconds.
- HTTP evidence records fixed metadata, status, byte count, and a body digest. It does not record
  request values, response text, full URLs, or authentication material.

Before production use, separately plan the currently unimplemented enterprise boundary: TLS and
authentication for non-loopback serving, tenant isolation, centralized policy/RBAC, key rotation,
backup and disaster recovery, retention controls, monitoring, and deployment-specific red-team and
evaluation coverage.
