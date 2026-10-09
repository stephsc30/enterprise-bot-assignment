# Enterprise Bot DevOps take-home

Python service, Helm chart, repeatable kind setup and debugging lab.
**Part 4 is incomplete: latest recorded result 9/11 passing.** Reporter
readiness and its `/report` Pod count still fail. See [FINDINGS](lab/FINDINGS.md)
for fixes, evidence and the unresolved issue.

## Run locally

From the repository root, use Linux or Ubuntu WSL2 with Bash, Docker serving
Linux containers, kind, kubectl and Helm. Docker must be reachable without an
interactive sudo prompt. Downloads require internet access; no cloud account
is needed.

```bash
./setup.sh
./setup.sh
```

The script creates or reuses kind cluster `demo`, installs ingress-nginx,
builds/loads the service image and deploys release `demo` in namespace `demo`.
It exports kubeconfig and switches the current context to `kind-demo`.
Helm upgrades reset values to the chart/script defaults.

Windows prevented binding port 80 on my WSL workstation. The tested commands
use these overrides on both runs:

```bash
export DEMO_HTTP_PORT=8080
export DEMO_HTTPS_PORT=8443
./setup.sh
./setup.sh
```

Defaults are 80/443. For an existing cluster, use the same port settings it was
created with. A mismatch produces an error; the script never deletes the cluster.
Host ports bind to loopback. HTTPS mapping does not provision a certificate;
the demo verification uses HTTP.

## Verify

```bash
kubectl --context kind-demo -n demo rollout status deployment/demo --timeout=180s
kubectl --context kind-demo -n demo get deploy,pods,svc,ingress
port=${DEMO_HTTP_PORT:-80}
curl --noproxy '*' --fail --silent --show-error \
  --resolve "demo.local:${port}:127.0.0.1" "http://demo.local:${port}/"
curl --noproxy '*' --fail --silent --show-error \
  --resolve "demo.local:${port}:127.0.0.1" "http://demo.local:${port}/healthz"
```

Expect two ready replicas. `/` returns `app`, `version` and the serving Pod's
hostname; defaults are `eb-demo`/`1.0.0`. `/healthz` returns 200 and
`{"status":"ok"}`. `--resolve` avoids changing the hosts file.

The application reads required `APP_NAME` and `VERSION` environment variables.
In Helm, `CONFIG_DIR` also enables reading mounted ConfigMap files on each
request. This makes direct ConfigMap patches visible without replacing Pods;
process environment variables themselves do not update. Volume projection is
asynchronous, so allow time for kubelet to refresh the files. The mount uses
the whole ConfigMap directory rather than `subPath`.

```bash
kubectl --context kind-demo -n demo patch configmap demo --type merge \
  -p '{"data":{"APP_NAME":"patched-app","VERSION":"7.7.7"}}'
# After volume propagation, check each replica:
for pod in $(kubectl --context kind-demo -n demo get pods \
  -l app.kubernetes.io/instance=demo -o jsonpath='{.items[*].metadata.name}'); do
  kubectl --context kind-demo -n demo exec "$pod" -- \
    python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080/", timeout=5).read().decode())'
done
kubectl --context kind-demo -n demo patch configmap demo --type merge \
  -p '{"data":{"APP_NAME":"eb-demo","VERSION":"1.0.0"}}'
```

Helm configuration changes also update a Deployment checksum. Setup uses a tag
derived from the image content ID so changed builds trigger a rollout.

## Chart and lab

```bash
bash -n setup.sh
helm lint ./chart
helm lint ./lab/broken-chart
helm template demo ./chart -n demo \
  --set replicaCount=3 --set config.appName=override-demo \
  --set-string config.version=9.9.9 --set ingress.host=override.local
```

Values expose replica count, image repository/tag, configuration, ingress host
and resources. The app defaults to two replicas, with readiness/liveness probes,
ConfigMap, Service and Ingress.

Setup installs the main app; install the lab separately. On a fresh cluster,
apply the original namespace manifest first to avoid the supplied driver's
directory-application ordering issue:

```bash
kubectl config use-context kind-demo
cd lab
kubectl apply -f cluster-state/namespace.yaml
bash ./scenario.sh up
kubectl -n debug-lab get deploy,pods,job
bash ./scenario.sh verify
```

Allow workloads to settle before verification. The latest recorded verifier
exited 2: **9 passing, 2 failing**. Helm `deployed` does not mean the reporter
is healthy. Protected lab files and the supplied image repository/tag remain
unchanged.

## Resource and implementation choices

The multi-stage image uses `python:3.13.16-slim-bookworm`, copies a virtual
environment into the runtime stage and runs as UID/GID 10001. Flask/Gunicorn
direct dependencies are pinned. Gunicorn uses one worker and two threads, with
its unused control socket disabled.

| Workload | CPU request / limit | Memory request / limit | Reason |
| --- | --- | --- | --- |
| Main app, per replica | 50m / 200m | 64Mi / 128Mi | Modest baseline and bounded bursts for a small local HTTP service. |
| Fixed lab metrics | 50m / 200m | 64Mi / 128Mi | Fits the LimitRange, replacing rejected 2/4 CPU settings. |
| Other lab Deployments | 50m / 200m | 64Mi / 128Mi | Retains handout values; sufficient for observed local checks. |

These are startup/smoke-tested, not load-tested production sizes. Production
sizing should measure latency, CPU throttling, memory working set and OOMs
under realistic concurrency. The main app has a 64Mi writable `/tmp`; the worker
has a 64Mi cache volume. Both are ephemeral; other root filesystem paths remain
read-only.

## Validation performed

- Built/ran the container and verified HTTP endpoints after fixing the unused
  Gunicorn control-socket startup failure.
- Ran setup successfully twice; the second run exited 0 with the same two
  app Pods ready and zero restarts.
- Verified ingress and patched the ConfigMap. Both existing Pods returned
  `patched-app`/`7.7.7` without replacement, then configuration was restored.
  The pasted transcript is retained in `lab/evidence/setup-validation.txt`;
  it is not represented as a `script` recording.
- Rendered overrides and linted both charts; recorded lab debugging and the
  original verifier's final 9/11 result.

Tested with Ubuntu 24.04 WSL2, kind 0.33.0, kubectl 1.33.3, Helm 3.18.4 and
Kubernetes 1.34.11. Setup pins the node image by digest and ingress chart 4.15.1.
Kubernetes 1.34 was selected for this host's cgroup v1 environment. This is not
cross-platform or cross-version validation. A later disposable compatibility
test stalled in Docker information requests before running the reporter.

## Deliberate gaps, risks and production changes

- **Reporter unresolved:** two automated checks fail. Correct RBAC and valid
  independent API responses did not resolve the image's JSON parsing error.
  Next step is maintainer clarification and verification of a permitted fix.
- **Single-node local infrastructure:** two replicas do not survive host loss.
  Production needs failure-domain placement, disruption planning, capacity
  testing, monitoring and alerting.
- **Retired ingress controller:** installed because the task requires it.
  [Kubernetes announced maintenance would end in March 2026](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/).
  Use a maintained Gateway API implementation in production; see [ANSWERS](ANSWERS.md).
- **No application TLS/authentication or NetworkPolicies:** unsuitable for
  sensitive public traffic. Add certificate management, appropriate access
  controls and tested network policies.
- **No CI/Trivy bonus, SBOM or signing:** vulnerabilities and dependency drift
  are not automatically gated. Pin production base images by digest, lock
  transitive dependencies, scan/sign builds and automate updates.
- **Minimal configuration/health handling:** missing mounted files cause `/`
  to fail, while `/healthz` only checks the HTTP process. Validate configuration
  and make readiness reflect required settings before production use.
- **Host workarounds:** Docker reported cgroup v1, non-default seccomp and
  `DOCKER_INSECURE_NO_IPTABLES_RAW`. Setup does not configure these daemon
  settings. Validate on a supported host with normal security defaults.

## How I used AI

I used ChatGPT/Codex for planning, implementation of the service/chart/setup,
diagnostic commands, interpreting outputs and drafting documentation. I ran
interactive commands in Ubuntu WSL; Codex also ran diagnostics on the same
local cluster, recorded separately in `lab/part4-assisted.log`. This was
substantial implementation/debugging assistance, not only proofreading.

Corrections included disabling Gunicorn's control socket, fixing a local test
fixture's permissions, using available host ports, setting the image's numeric
UID, and distinguishing successful RBAC authorization from reporter health.
HTTP/2 and Kubernetes-version hypotheses did not establish a fix. Documentation
was checked against real output; no all-green result or reporter root cause is
claimed. I stopped further speculative reporter debugging and retained the
unresolved issue and next steps rather than hiding the failure.
