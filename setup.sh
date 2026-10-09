#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

CLUSTER=demo
CONTEXT=kind-demo
NAMESPACE=demo
RELEASE=demo
# Compatible with this workstation's cgroup v1 host; upgrade after moving to v2.
NODE_IMAGE=kindest/node:v1.34.11@sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d
INGRESS_CHART_VERSION=4.15.1
# Override these on hosts where the standard HTTP/HTTPS ports cannot be bound.
DEMO_HTTP_PORT=${DEMO_HTTP_PORT:-80}
DEMO_HTTPS_PORT=${DEMO_HTTPS_PORT:-443}

for port in "$DEMO_HTTP_PORT" "$DEMO_HTTPS_PORT"; do
  if [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
    echo "Host ports must be integers between 1 and 65535: $port" >&2
    exit 1
  fi
done
if [ "$DEMO_HTTP_PORT" = "$DEMO_HTTPS_PORT" ]; then
  echo "HTTP and HTTPS must use different host ports." >&2
  exit 1
fi

for tool in docker kind kubectl helm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

docker info >/dev/null
if [ "$(docker info --format '{{.OSType}}')" != linux ]; then
  echo "Docker must be configured for Linux containers." >&2
  exit 1
fi

if [ ! -f service/Dockerfile ] || [ ! -f chart/Chart.yaml ]; then
  echo "Run this script from a repository containing service/ and chart/." >&2
  exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -f -- "$work_dir/kind.yaml"; rmdir -- "$work_dir"' EXIT

diagnostics() {
  local status=$?
  echo "Setup failed." >&2
  if kubectl config get-contexts "$CONTEXT" -o name 2>/dev/null | grep -Fxq "$CONTEXT"; then
    kubectl --context "$CONTEXT" --request-timeout=10s get pods -A >&2 || true
    kubectl --context "$CONTEXT" --request-timeout=10s -n "$NAMESPACE" get events \
      --sort-by=.metadata.creationTimestamp >&2 || true
  else
    echo "Cluster creation did not complete; Kubernetes diagnostics are not available yet." >&2
  fi
  exit "$status"
}
trap diagnostics ERR

echo "==> Checking the application chart"
helm lint ./chart

cat > "$work_dir/kind.yaml" <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: $DEMO_HTTP_PORT
        listenAddress: "127.0.0.1"
        protocol: TCP
      - containerPort: 30443
        hostPort: $DEMO_HTTPS_PORT
        listenAddress: "127.0.0.1"
        protocol: TCP
YAML

clusters=$(kind get clusters)
if printf '%s\n' "$clusters" | grep -Fxq "$CLUSTER"; then
  echo "==> Reusing kind cluster $CLUSTER"
else
  echo "==> Creating kind cluster $CLUSTER"
  kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" \
    --config "$work_dir/kind.yaml" --wait 180s
fi

# Existing clusters must expose the ports used by this setup; never delete them.
http_binding=$(docker port demo-control-plane 30080/tcp 2>/dev/null || true)
https_binding=$(docker port demo-control-plane 30443/tcp 2>/dev/null || true)
if [ "$http_binding" != "127.0.0.1:$DEMO_HTTP_PORT" ] || [ "$https_binding" != "127.0.0.1:$DEMO_HTTPS_PORT" ]; then
  echo "The existing demo cluster does not have the expected port mappings." >&2
  echo "Expected 127.0.0.1:$DEMO_HTTP_PORT -> 30080 and 127.0.0.1:$DEMO_HTTPS_PORT -> 30443." >&2
  echo "For a cluster created with custom ports, set DEMO_HTTP_PORT and DEMO_HTTPS_PORT to those ports." >&2
  echo "Review the existing cluster before deciding whether to recreate it." >&2
  exit 1
fi

kind export kubeconfig --name "$CLUSTER"
kubectl --context "$CONTEXT" wait --for=condition=Ready nodes --all --timeout=180s

echo "==> Installing ingress-nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm repo update ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --kube-context "$CONTEXT" \
  --namespace ingress-nginx --create-namespace \
  --version "$INGRESS_CHART_VERSION" --reset-values \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  --set controller.service.externalTrafficPolicy=Cluster \
  --wait --wait-for-jobs --timeout 5m

echo "==> Building and loading the service image"
docker build --tag eb-demo:dev ./service
# A content-derived tag changes the Deployment when the image changes.
image_id=$(docker image inspect eb-demo:dev --format '{{.Id}}')
image_tag="build-${image_id#sha256:}"
docker tag eb-demo:dev "eb-demo:$image_tag"
kind load docker-image "eb-demo:$image_tag" --name "$CLUSTER"

echo "==> Deploying the application"
helm upgrade --install "$RELEASE" ./chart \
  --kube-context "$CONTEXT" \
  --namespace "$NAMESPACE" --create-namespace --reset-values \
  --set image.repository=eb-demo \
  --set-string "image.tag=$image_tag" \
  --set image.pullPolicy=IfNotPresent \
  --wait --timeout 3m

kubectl --context "$CONTEXT" -n "$NAMESPACE" \
  rollout status deployment/demo --timeout=180s
kubectl --context "$CONTEXT" -n "$NAMESPACE" get deploy,pods,svc,ingress

echo "Setup completed. Verify from the same machine with:"
echo "curl --noproxy '*' --resolve demo.local:$DEMO_HTTP_PORT:127.0.0.1 http://demo.local:$DEMO_HTTP_PORT/"
