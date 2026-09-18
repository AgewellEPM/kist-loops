# SML production qualification

The supported service is one operator-owned durable runtime on a local machine, bound to
loopback. Qualifying a release requires exercising its actual CLI binary, retained history,
recovery artifacts, and overload behavior. A passing Swift unit suite alone is insufficient.

Run the offline campaign against the candidate that will be deployed:

```sh
python3 scripts/tests/sml-production-qualification.py \
  --binary .build/release/kist \
  --output /private/tmp/kist-sml-production-qualification
```

The default campaign uses 300 individually approved HTTP operations over 120 seconds, four
clients, and a local fixture that records each effect before returning its response. It then
exercises recovery, three more 300-task archive/restart cycles, and the default admission
limits. It requires no provider credentials, browser, VM, container, or external network call.
Every project is temporary; child hosts and fixture threads are stopped and reaped in cleanup.

The output includes `qualification.json`, `report.md`, and per-host logs. The JSON records the
binary SHA-256, machine, workload, measurements, individual gates, effect counts, maintenance
results, and cleanup. A nonzero exit or any false gate fails qualification. Keep the complete
result alongside release test and deployment evidence. Rebuilding the binary requires fresh
evidence for its new digest.

## Required behavior

| Campaign | Required evidence |
|---|---|
| Sustained dispatch | All 300 tasks complete, each fixture effect occurs once, and offered-to-completed p95 is below five seconds. |
| Operator responsiveness | `/approvals` p95 below one second, p99 below two seconds, and mutation p95 below two seconds during the workload. |
| Slow client | An incomplete request does not hold another operator request for one second or longer. |
| Racing approvals | Exactly one approval succeeds, the stale revision returns 409, and one effect occurs. |
| Host ownership | A second CLI refuses the same project without changing its session token. |
| Graceful stop | A held in-flight response completes during SIGTERM shutdown, exit succeeds within five seconds, and the token is removed. |
| Abrupt stop | SIGKILL after the recorded effect preserves the unresolved claim through restart and a periodic drain; reconciliation never repeats it. |
| Fresh-project restore | A backup reconstructs configuration and a role-preserving source set without copying original project files; the restored host can execute a new approved task. |
| Stale backup | Work backed up before its later external effect becomes a failed, quarantined task on fresh restore and is not automatically replayed. |
| Existing-project restore | An exact current digest is required, replaced bytes are quarantined, later terminal history is retained, and conflicting owner configuration is preserved. |
| Retained history | Three more 300-task cycles preserve more than 1,000 archived tasks; each cycle keeps operator p95 below one second. Old task history remains queryable and old IDs cannot be reused. |
| Admission pressure | The 65th unfinished task and 501st retained task return 503 without persisting a new replay claim. Existing work can finish and admission resumes when capacity is available. |
| Maximum responses | Individually approved 64 KiB responses finish once each; new work is refused at the 2 MiB hot-store pressure boundary. |
| Health | Authenticated health reports capacity transitions and in-flight/unresolved claim counts without asserting external success. |

The limits are separate: at most 500 hot tasks, 64 unfinished tasks, and 2 MiB of hot-store
data before admitting more work. An admitted operation may finish after byte pressure is
reached; the host must retain its result rather than reject persistence after an effect.
Archive terminal history during explicit maintenance to regain capacity. Increasing the
limits requires a new qualification campaign for that envelope; a larger configuration must
not be presented as already qualified.

This campaign tests a concrete local workload and its failure cases. It does not establish
unlimited throughput or an external exactly-once guarantee. In particular, arbitrary loss of
post-backup task history cannot reveal effects whose identities were never present in the
backup or surviving archive. Recovery preserves available evidence and prevents automatic
replay of restored unfinished work; operators still reconcile uncertain external outcomes.
