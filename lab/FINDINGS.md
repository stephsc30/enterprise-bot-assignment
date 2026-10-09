# Findings — Part 4 debug lab

## Result and evidence

**Incomplete: 9/11 passing.** Reporter readiness and `/report` still fail.
Investigated on 2026-10-09 in Ubuntu 24.04 WSL2, kind, Kubernetes 1.34.11.
The supplied image remains `docker.io/ebinterview/eb-debug-app:1.0.1`, observed
digest `sha256:17f41698c10f5c18693339281b92d3cfef16d9fcffcad440a24e7ab19e05c443`.
`scenario.sh` and `cluster-state/` match the original handout.

`part4-session.log` is the original interactive recording. Subsequent
AI-assisted diagnostics against the same cluster are in `part4-assisted.log`.
Some assisted sessions overlap in that appended log. Excerpts below remove
terminal formatting and omit unrelated lines; the genuine recordings remain.

## Defect 1 — Invalid migration Job restart policy

**Symptom.** `bash ./scenario.sh up` produced:

```text
* Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"
```

**Cause.** The Job Pod template used `restartPolicy: Always`.

**Fix.** Set `Never`; retained `backoffLimit: 2` for Job-controlled retries.

**How I found it.** Followed the Helm/API validation error to
`templates/migrate-job.yaml`, corrected the policy and reapplied. The final
verifier reports `PASS  migrate Job completed`. Helm release status alone was
not treated as proof of completion.

## Defect 2 — Listener and probe ports disagree

**Symptom.** Pod events included this excerpt:

```text
Readiness probe failed: Get "http://10.244.0.21:8080/healthz": dial tcp 10.244.0.21:8080: connect: connection refused
```

Startup logs explained the listener:

```text
2026/10/09 13:19:42 eb-debug-app 2.0.0 starting: mode=gateway pod=gateway-64cbdf67c-67w2c listening on :8081 (image default is 8081; set PORT to override)
```

**Cause.** `containerPort` does not configure the application. The image
defaulted to 8081 while chart probes/targets used `common.port: 8080`.

**Fix.** Added `PORT: {{ .Values.common.port | quote }}` as an environment
entry to all five Deployments, aligning the listener with the chart setting.

**How I found it.** Compared events, logs and configuration, then redeployed.
Backend health subsequently passed. Reporter changed from connection refusal
to HTTP 503, revealing a separate problem.

## Defect 3 — Worker needs writable cache storage

**Symptom.** Worker logs:

```text
2026/10/09 13:20:03 FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

**Cause.** The read-only root filesystem had no writable mount covering the
required cache directory.

**Fix.** Mounted a 64Mi `emptyDir` at `/var/cache/app`, with Pod `fsGroup: 65532`
for non-root writes. Kept the root filesystem read-only and retained the other
security restrictions. Cache contents are disposable across Pod deletion.

**How I found it.** Read failing worker logs and compared the required path
with its mounts/security context. After redeployment the verifier reports
`PASS  deployment worker: 1/1 ready` and no CrashLoopBackOff Pods.

## Defect 4 — Metrics resources violate the LimitRange

**Symptom.** ReplicaSet `FailedCreate` events included:

```text
Error creating: pods "metrics-5db5c7d87b-b94kl" is forbidden: maximum cpu usage per Container is 1, but limit is 4
```

**Cause.** Metrics requested 2 CPUs and limited itself to 4; namespace
guardrails allow at most 1 CPU per container. Admission prevented Pod creation.

**Fix.** Changed CPU request/limit to `50m`/`200m`; retained memory `64Mi`/`128Mi`.
These are local-demo starting values, not load-tested production sizing. Did
not edit `cluster-state/limits.yaml`.

**How I found it.** Followed the unready Deployment to ReplicaSet events and
compared them with `kubectl -n debug-lab get limitrange -o yaml`. After applying
the values, the verifier reports `PASS  deployment metrics: 1/1 ready`.

## Defect 5 — Gateway uses the wrong backend namespace

**Symptom.** Intermediate verifier output:

```text
PASS  backend answers on http://backend:8080/healthz
FAIL  gateway /status does not report backend=ok
```

The gateway Deployment environment returned:

```json
[{"name":"PORT","value":"8080"},{"name":"APP_MODE","value":"gateway"},{"name":"APP_NAME","value":"gateway"},{"name":"BACKEND_URL","value":"http://backend.default.svc:8080"},{"name":"VERSION","value":"2.0.0"}]
```

**Cause.** The Service lives in `debug-lab`; the URL explicitly selected `default`.

**Fix.** Set `gateway.env.BACKEND_URL` to `http://backend:8080`, using the
same-namespace Service name.

**How I found it.** Contrasted successful backend health with failed gateway
aggregation, then inspected the gateway environment. After correcting the URL
and rolling out, the recorded response was:

```json
{"app":"gateway","backend":"ok","backend_url":"http://backend:8080","pod":"gateway-6b94484596-5lgwn","self":"ok","version":"2.0.0"}
```

## Defect 6 — Reporter RoleBinding selects the wrong account

**Symptom.** This diagnostic returned `no`:

```bash
kubectl auth can-i list pods -n debug-lab \
  --as=system:serviceaccount:debug-lab:reporter
```

`kubectl -n debug-lab get rolebinding reporter-read -o yaml` showed:

```yaml
subjects:
- kind: ServiceAccount
  name: default
  namespace: debug-lab
```

**Cause.** The Pod uses `reporter`, but the binding granted Pod-read access to
`default` instead.

**Fix.** Used `{{ .Values.reporter.serviceAccountName }}` as the binding subject,
retaining the release namespace and only the existing `get`/`list` verbs on
Pods. No cluster-wide permissions were added. The handout's ServiceAccount
object itself remains named `reporter`; renaming that value is not consistently
supported by all original templates.

**How I found it.** Compared impersonated authorization, binding subjects and
the Deployment's ServiceAccount. After applying the fix, the same command
returned `yes`. An independent client using that account fetched a valid Pod
list. The authorization defect is fixed; reporter behavior is still not healthy.

## Additional startup compatibility issue — named image user

**Symptom.** Kubelet event excerpt:

```text
Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root
```

**Cause.** The image configured username `nonroot`, while the Pod required
non-root execution without supplying a numeric UID.

**Fix.** Set `runAsUser: 65532` and `runAsGroup: 65532` in all six workload
container security contexts. Retained `runAsNonRoot`, capability restrictions,
read-only root filesystems and disabled privilege escalation.

**How I found it.** Followed `CreateContainerConfigError` to events, inspected
image metadata, and read `/etc/passwd` from a stopped temporary container:

```text
Configured user: "nonroot"
nonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin
```

Removed the inspection container afterward. No application source was extracted
and no image rebuilt. This extra observed issue is documented separately from
the six configuration defects rather than omitted to force a count of six.

## Unresolved — reporter Pod-list parsing

**Symptom.** With correct RBAC, reporter still logs:

```text
pod list failed: parse pod list: unexpected end of JSON input
```

Its `/healthz` and `/report` return 503. A Python diagnostic using the reporter
ServiceAccount, token and CA returned this actual output (no token printed):

```text
HTTP status: 200
Content-Type: application/json
Content-Encoding: None
Content-Length: None
Received bytes: 54022
JSON parsing: successful
Response kind: PodList
Pod count: 8
```

**Cause.** Not established. The evidence points toward response handling in
the supplied reporter or a client/server interaction. Chunked encoding is a
hypothesis, not a confirmed root cause.

**Investigation.** Restarting did not help. Independent API requests with
different timeouts and pagination succeeded. A temporary reporter with HTTP/2
disabled still failed. An isolated namespace containing one reporter Pod and
correct RBAC reproduced the problem:

```text
Attempt 1 503 {"error":"parse pod list: unexpected end of JSON input","status":"unhealthy"}
Attempt 2 503 {"error":"parse pod list: unexpected end of JSON input","status":"unhealthy"}
Attempt 3 503 {"error":"parse pod list: unexpected end of JSON input","status":"unhealthy"}
API response bytes: 6995 Pod count: 1
```

A disposable Kubernetes 1.32.8 test stalled during node preparation/Docker
information requests and was stopped before running the reporter. It does not
establish a version-based fix. Diagnostic resources were removed; `demo` remains.

**Next step.** Ask the maintainer to reproduce the image on Kubernetes 1.34.11
and confirm a tested version or authorized correction. The minimal manifest is
`diagnostics/reporter-isolation.yaml`; see `reporter-investigation.md` for more
detail. No image replacement, probe weakening or verifier modification was used.

## Environment observations and final verification

The driver initially attempted to apply the LimitRange before its namespace
existed. Applied the original namespace manifest, then the original limits
manifest explicitly, without editing them. This bootstrap ordering observation
is separate from chart fixes.

An earlier backend probe failure did not reproduce in three direct BusyBox
requests or the final verifier. Its transient cause is unknown. The final trace
also contains unscored `PROBE_DNS=fail` from `nslookup`, although backend and
gateway HTTP requests using Service DNS names succeeded. This discrepancy
was not resolved.

Final original-verifier output in `part4-assisted.log`, formatting removed:

```text
PASS  migrate Job completed
PASS  deployment backend: 1/1 ready
PASS  deployment gateway: 1/1 ready
PASS  deployment worker: 1/1 ready
FAIL  deployment reporter: 0/1 ready
PASS  deployment metrics: 1/1 ready
PASS  no pods in CrashLoopBackOff
PASS  ServiceAccount debug-lab/reporter can list pods
PASS  backend answers on http://backend:8080/healthz
PASS  gateway /status reports backend=ok
FAIL  reporter /report does not return a pod count

2 check(s) failing, 9 passing. Keep digging — every failure is a symptom.
```

The original interactive recording ends with the earlier 8/11 result; the later
9/11 result is in the assisted recording. Part 4 remains incomplete.
