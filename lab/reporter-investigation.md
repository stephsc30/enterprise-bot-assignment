# Reporter investigation — unresolved

Observed on 2026-10-09, in the candidate's Ubuntu WSL environment and kind
`demo` cluster (Kubernetes 1.34.11). AI-assisted diagnostic commands and their
actual output were recorded separately in `part4-assisted.log`; the candidate's
original recording is `part4-session.log`. Some diagnostic sessions overlap in
the appended assisted log. Neither recording is a fabricated reconstruction.

## Current result

The original, unmodified `scenario.sh verify` was rerun with shell tracing.
Its final output was:

```text
2 check(s) failing, 9 passing. Keep digging — every failure is a symptom.
```

The two failures are reporter Deployment readiness and the reporter `/report`
pod count. Backend health, gateway aggregation, worker, metrics, migration,
reporter authorization and the no-CrashLoop check pass. The earlier backend
probe failure did not reproduce in three direct BusyBox requests or the final
verifier run. Its original transient cause has not been established.

The trace also contained `PROBE_DNS=fail` from BusyBox `nslookup`; this is not
one of the verifier's scored checks. Service HTTP requests using backend and
gateway DNS names succeeded. That discrepancy has not been investigated further.

## What was established

- The RoleBinding now binds `reporter-read` to the configured `reporter`
  ServiceAccount in the release namespace. Authorization checks return yes.
- A temporary Python client using that ServiceAccount, its mounted token and
  CA certificate successfully fetched the namespace's Pod list: HTTP 200,
  valid JSON, `kind: PodList`. No token was printed.
- Repeated requests returned complete lists in less than one second. Responses
  were chunked and did not specify Content-Length. A paginated `limit=1`
  request also returned valid JSON.
- The supplied reporter continued logging:

  ```text
  pod list failed: parse pod list: unexpected end of JSON input
  ```

- Reporter `/healthz` and `/report` returned HTTP 503. Restarting the reporter
  did not resolve this.
- A temporary reporter using the same image with HTTP/2 disabled via
  `GODEBUG=http2client=0` also failed. This setting was not added to the chart.
- A minimal reproduction in a separate namespace, containing one reporter Pod
  with correct Pod-list RBAC, also failed. The API's one-Pod response parsed
  successfully with an independent client.
- A separate Kubernetes 1.32.8 kind compatibility experiment was attempted but
  stopped while node preparation stalled in Docker information requests. The
  reporter never ran there. No conclusion about version compatibility can be
  drawn from that attempt, and setup's Kubernetes version was not changed.
- The diagnostic Pods/namespaces were removed. The existing `demo` cluster and
  its lab workloads were retained. Protected lab files match `handout-baseline`.

## Assessment and next step

The observations point toward response handling in the supplied reporter, or
an interaction between that client and this Kubernetes environment. They do
not prove the exact application defect. In particular, chunked encoding is a
hypothesis, not a confirmed root cause. This investigation did not access the
application source or replace its image.

Ask the assignment maintainer to reproduce `ebinterview/eb-debug-app:1.0.1`
reporter mode on Kubernetes 1.34.11 and confirm the supported/tested Kubernetes
version or provide an authorized correction. Include the minimal reproduction
and the contrast between successful API requests and the reporter's parsing
error. A successful compatibility test would be required before proposing a
Kubernetes version change.

Do not describe Part 4 as complete: the current result is 9/11. The image tag,
probes and verifier have not been changed to conceal these failures.
