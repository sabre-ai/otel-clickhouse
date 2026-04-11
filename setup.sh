#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="sabre-ch-demo"
NAMESPACE="otel-demo"
CLICKSTACK_NS="default"

echo "=== SABRE ClickHouse Demo Setup ==="
echo ""

# --- Pre-flight checks ---
for cmd in kubectl helm kind; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed."
    exit 1
  fi
done

# --- Step 1: Create kind cluster ---
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "[1/6] Kind cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  echo "[1/6] Creating kind cluster '${CLUSTER_NAME}'..."
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30900
        hostPort: 9000
        protocol: TCP
      - containerPort: 30300
        hostPort: 3000
        protocol: TCP
EOF
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

# --- Step 2: Install cert-manager (ClickStack dependency) ---
echo "[2/6] Installing cert-manager..."
if kubectl get namespace cert-manager &>/dev/null; then
  echo "  cert-manager namespace exists, skipping."
else
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  echo "  Waiting for cert-manager pods..."
  kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
fi

# --- Step 3: Install ClickStack via Helm ---
echo "[3/6] Installing ClickStack..."
helm repo add clickstack https://clickstack.github.io/helm-charts 2>/dev/null || true
helm repo update clickstack

if helm list -q | grep -q "^clickstack$"; then
  echo "  ClickStack already installed, skipping."
else
  helm install clickstack clickstack/clickstack \
    --set clickhouse.service.type=NodePort \
    --set clickhouse.service.nodePorts.native=30900 \
    --wait --timeout 300s
fi

# --- Step 4: Deploy OpenTelemetry demo application ---
echo "[4/6] Deploying OpenTelemetry demo application..."
kubectl create namespace "${NAMESPACE}" 2>/dev/null || true

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update open-telemetry

if helm list -n "${NAMESPACE}" -q | grep -q "^otel-demo$"; then
  echo "  OTel demo already installed, skipping."
else
  helm install otel-demo open-telemetry/opentelemetry-demo \
    -n "${NAMESPACE}" \
    --set components.frontendProxy.service.type=NodePort \
    --wait --timeout 600s
fi

# --- Step 5: Configure OTel Collector to export to ClickStack ---
echo "[5/6] Configuring OTel Collector to export to ClickStack..."
CLICKHOUSE_ENDPOINT="clickstack-clickhouse.${CLICKSTACK_NS}.svc.cluster.local:9000"

kubectl apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-clickhouse-config
data:
  relay.yaml: |
    exporters:
      clickhouse:
        endpoint: tcp://${CLICKHOUSE_ENDPOINT}?dial_timeout=10s
        database: default
        logs_table_name: otel_logs
        traces_table_name: otel_traces
        metrics_table_name: otel_metrics
        ttl_days: 3
        timeout: 5s
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s
    service:
      pipelines:
        logs:
          exporters: [clickhouse]
        traces:
          exporters: [clickhouse]
        metrics:
          exporters: [clickhouse]
EOF

echo "  NOTE: You may need to configure the OTel demo's collector to use this exporter."
echo "  See README.md for details on connecting the collector pipeline to ClickStack."

# --- Step 6: Wait and print access info ---
echo "[6/6] Waiting for pods to be ready..."
kubectl wait --for=condition=Ready pod --all -n "${NAMESPACE}" --timeout=600s 2>/dev/null || true

echo ""
echo "=== Setup Complete ==="
echo ""
echo "ClickHouse native port: localhost:9000 (via kind NodePort)"
echo ""
echo "To verify data ingestion:"
echo "  clickhouse-client --query 'SELECT count() FROM otel_logs'"
echo ""
echo "To port-forward ClickHouse (if NodePort not working):"
echo "  kubectl port-forward svc/clickstack-clickhouse 9000:9000 &"
echo ""
echo "To use with SABRE:"
echo "  uv run sabre"
echo "  > use clickhouse integration"
echo "  > Investigate: <describe the issue>"
echo ""
