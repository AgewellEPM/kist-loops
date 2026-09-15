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
operations and approval authorities it needs. Every present host trust file is loaded through one
bounded, stable, descriptor-confined read and must be a single-link regular file owned by the
runtime user with exact mode `0600`:

```bash
chmod 600 \
  .kist/sml/authority.json \
  .kist/sml/catalog.json \
  .kist/sml/policy.json \
  .kist/sml/models.json \
  .kist/sml/retrieval.json
```

The default policy gates every externally advanced instruction. An absent `.kist/sml/policy.json`
means `approve_always`; do not add a relaxation unless the host owner has reviewed its effect.
Absent model or retrieval bindings leave those admitted steps visibly parked. A present file with
unknown or duplicate fields, invalid types, excessive entries, an out-of-range budget, a symlinked
ancestor or leaf, a hard link, or any other unsafe file state aborts launch instead of falling back.

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

## Model output types

`CALL_MODEL` uses the workflow's `output_schema` as a named **top-level type contract**.
Built-ins are `text`, `string`, `json.object`, `json.array`, `json.boolean`, `json.number`, and
`json.integer`. The first two accept plain text; the JSON contracts require a single JSON value
of the indicated type, with no Markdown fences. Responses are bounded to 64 KiB. Invalid JSON,
duplicate keys, wrong types, and empty responses fail the step instead of becoming successful state.

For an existing custom schema name, map its actual output type in the owner-only
`.kist/sml/models.json` file. For example, a workflow using purpose `plan` and schema `plan.v1`
with an object output field uses this binding (replace the model with your configured model):

```json
{
  "schema_version": 1,
  "purposes": {
    "plan": {"provider": "codex-cli", "model": "your-configured-model", "max_tokens": 4096}
  },
  "output_schemas": {"plan.v1": "object"}
}
```

Admit `plan` in `model_purposes` and `plan.v1` in `model_output_schemas` in the host catalog.
The driver preserves the parsed object in state. Type-string mappings remain supported. For a
nested contract, use an object-form schema in the same `output_schemas` map:

```json
{
  "plan.v2": {
    "type": "object",
    "required": ["steps"],
    "additionalProperties": false,
    "properties": {
      "steps": {
        "type": "array", "minItems": 1, "maxItems": 20,
        "items": {
          "type": "object", "required": ["title", "priority"],
          "additionalProperties": false,
          "properties": {
            "title": {"type": "string", "minLength": 1, "maxLength": 120},
            "priority": {"type": "integer", "minimum": 1, "maximum": 5}
          }
        }
      }
    }
  }
}
```

Place that entry under `output_schemas` in `models.json`, admit `plan.v2` in the catalog, and
set the CALL_MODEL instruction's `output_schema` to `plan.v2`. The host puts the compact contract
in the prompt, parses strict JSON, recursively validates every constrained field/item, and only
then records success and patches state. Missing required members, wrong types, forbidden extras,
out-of-range values, malformed JSON or duplicate keys produce a failed outcome. Evidence binds
the exact contract digest. Application-specific facts still require a workflow verifier.

The supported JSON Schema subset requires one `type` at every schema node: `object`, `array`,
`string`, `number`, `integer` or `boolean`. Object schemas support `properties`, `required`, boolean
`additionalProperties`, `minProperties` and `maxProperties`. Array schemas support a single
object-form `items` schema and `minItems`/`maxItems`. Strings support `minLength`/`maxLength`,
counted in Unicode code points. Numbers support inclusive `minimum`/`maximum` and numeric
`exclusiveMinimum`/`exclusiveMaximum`. Properties are optional unless required; extras are allowed
unless explicitly disabled. These meanings follow the primary JSON Schema references for
[objects](https://json-schema.org/understanding-json-schema/reference/object),
[arrays](https://json-schema.org/understanding-json-schema/reference/array),
[strings](https://json-schema.org/understanding-json-schema/reference/string), and
[numbers](https://json-schema.org/understanding-json-schema/reference/numeric).

This is a bounded subset: unsupported keywords (including `$ref`, composition, `enum`, `pattern`,
`format`, and nullable/type unions) fail configuration loading. Required names must also appear
in `properties`; property names follow SML state-key rules. Schema nesting is limited to 8,
schema nodes to 256, and the compact schema to 16 KiB; host config JSON ingress limits also apply.
Object size constraints cannot exceed 256, array sizes 1,024, and string lengths 65,536. Invalid,
negative, fractional size limits or contradictory bounds fail loading. Omitted constraints remain
unrestricted within the existing SML wire/state limits, including the 65,536-byte model response.

Existing text workflows using `text`, `string`, or a custom type-string mapping to `string` keep
plain-text behavior. An explicit object-form `{ "type": "string" }` contract instead requires a
JSON string, including quotes, and can validate an empty string when its length constraints allow.
Unknown schema names fail before a model call, with the configuration path in the error.

## Retrieval provider wiring

Durable hosts use Kist's configured embedding provider, under the same provider admission policy
as ordinary semantic memory. The host never enables another provider implicitly. A present,
admitted retrieval binding without a permitted configured embedder now fails launch with an
actionable message, instead of leaving an approved task parked indefinitely.

For a local Ollama embedding provider already permitted by your Kist configuration, set
`KIST_EMBEDDER=ollama` and optionally `KIST_EMBED_MODEL` (default `nomic-embed-text`). This requires
an already running Ollama service and an already installed embedding model. Alternatively, an
admitted Gemini provider with configured credentials uses Kist's Gemini embedder. This command
does not install a model or change provider permissions.

An owner-only `.kist/sml/retrieval.json` binding points to an existing vector store:

```json
{
  "schema_version": 1,
  "sources": {
    "notes": {
      "store_path": ".kist/memory/vectors.json",
      "embedding_space": "the-exact-embedding-space-recorded-in-your-store",
      "top_k": 5
    }
  }
}
```

Admit `notes` in the catalog's `retrieval_sources`. Relative store paths resolve against
`--project`. The configured space must match the provider identity before and after embedding;
Ollama identities include the model manifest digest. Existing records must carry compatible
embedding identity and temporal provenance. A mismatch fails retrieval and does not compare
vectors from different models. The `RETRIEVE` instruction's `output_field` names an array state
field; each hit contains `text` and `score`.

The focused offline regression suite uses scripted model providers and a temporary vector store
with an injected embedding provider; it makes no live provider calls:

```sh
swift test --filter 'SMLModelOutputContractTests|SMLProductionDriverTests|KistSMLRuntimeDriverWiringTests|ToolGateTests|SMLHTTPCapabilityDriverTests'
```


## Failed and interrupted tasks

A definite tool, model, observation, or retrieval failure now finishes the task with status
`failed`. Its `step_recorded` receipt retains the failed outcome and dispatch evidence, and the
capability claim is cleared. Unknown outcomes, including interrupted execution, retain the claim
for operator inspection.

To retire an interrupted claim, stop its original host and restart the durable host on the same
project. Grant `task.reconcile` explicitly in the operator's `authority.json` operations. Use
`watch TASK-ID` to obtain the latest `task_revision` and `capability_dispatch_id`, then run the
workflow REPL command:

```text
reconcile TASK-ID {"task_revision":2,"dispatch_id":"DISPATCH-ID","note":"Previous host stopped; retiring interrupted task after review"}
```

The equivalent API request is `POST <workflow-api-path>/tasks/TASK-ID/reconcile`, with that JSON
object as its body. The global SML command compiler also accepts
`reconcile TASK-ID 2 DISPATCH-ID Previous host stopped; retiring interrupted task`.
Reconciliation requires the exact task revision, dispatch ID, a nonempty operator note, and a
claim from an earlier host lease. A claim from the current host session cannot be reconciled.

A successful reconciliation marks the task `failed`, clears its claim, and appends a `reconciled`
receipt with `outcome: abandoned` and `external_outcome: unknown`. The original claim receipt is
retained. This records the operator's decision to stop tracking that task; it does not retry the
operation, undo any external effect, or establish that the operation succeeded.

Existing runtime snapshots remain readable by the repaired binary. Once a snapshot contains a
`failed` task or a `reconciled` receipt, an older binary that does not recognize those enum values
cannot read it. Use the repaired binary for that store; the schema-v1 migration backup does not
provide an up-to-date rollback of these task changes.
