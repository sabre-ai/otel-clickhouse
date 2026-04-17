#!/usr/bin/env bash
set -euo pipefail

# Usage: ./setup.sh [data_limit]
#   data_limit: max ClickHouse storage size (default: 1Gi). Examples: 512Mi, 2Gi, 5Gi

CLUSTER_NAME="sabre-ch-demo"
NAMESPACE="otel-demo"
HOST_CH_PORT=19000
DATA_LIMIT="${1:-1Gi}"

echo "=== SABRE ClickHouse Demo Setup ==="
echo "  ClickHouse data limit: ${DATA_LIMIT}"
echo ""

# --- Pre-flight checks ---
echo "Checking prerequisites..."
PREFLIGHT_OK=true

for cmd in docker kubectl helm kind clickhouse jq; do
  if command -v "$cmd" &>/dev/null; then
    echo "  ✓ $cmd ($(command -v "$cmd"))"
  else
    case "$cmd" in
      clickhouse) hint="curl https://clickhouse.com/ | sh  OR  brew install clickhouse" ;;
      jq)         hint="brew install jq  OR  https://jqlang.github.io/jq/download/" ;;
      kind)       hint="https://kind.sigs.k8s.io/docs/user/quick-start/#installation" ;;
      helm)       hint="https://helm.sh/docs/intro/install/" ;;
      kubectl)    hint="https://kubernetes.io/docs/tasks/tools/" ;;
      docker)     hint="https://docs.docker.com/get-docker/" ;;
      *)          hint="" ;;
    esac
    echo "  ✗ $cmd — not found. Install: $hint"
    PREFLIGHT_OK=false
  fi
done

# Check Docker daemon is actually running (not just installed)
if command -v docker &>/dev/null; then
  if ! docker info &>/dev/null; then
    echo "  ✗ Docker daemon is not running. Please start Docker Desktop or the Docker service."
    PREFLIGHT_OK=false
  else
    echo "  ✓ Docker daemon is running"
  fi
fi

if [ "$PREFLIGHT_OK" = false ]; then
  echo ""
  echo "ERROR: Missing prerequisites. Please fix the issues above and re-run."
  exit 1
fi

echo ""

# Check host port is available (ClickHouse native protocol, mapped to 19000 to avoid macOS AirPlay on 9000)
# Use both lsof and netstat — lsof without root misses system services
PORT_IN_USE=false
if lsof -i :${HOST_CH_PORT} -P -n 2>/dev/null | grep -q LISTEN; then
  PORT_IN_USE=true
elif netstat -an 2>/dev/null | grep -qE "\.${HOST_CH_PORT}\s.*LISTEN"; then
  PORT_IN_USE=true
fi
if [ "$PORT_IN_USE" = true ]; then
  echo "ERROR: Port ${HOST_CH_PORT} is already in use."
  echo "  Check what's using it: lsof -i :${HOST_CH_PORT}"
  echo "  If a previous demo is running: ./teardown.sh"
  exit 1
fi

# --- Step 1: Create kind cluster ---
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "[1/5] Kind cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  echo "[1/5] Creating kind cluster '${CLUSTER_NAME}'..."
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30900
        hostPort: 19000
        protocol: TCP
EOF
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

# --- Step 2: Deploy standalone ClickHouse ---
echo "[2/5] Deploying ClickHouse..."
if kubectl get deploy clickhouse &>/dev/null; then
  echo "  ClickHouse already deployed, skipping."
else
  # OTel tables are created automatically by the bridge collector (create_schema: true)
  # Do NOT use init SQL — the exporter's schema includes columns that manual DDL misses
  kubectl apply -f - <<CHEOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: clickhouse
  labels:
    app: clickhouse
spec:
  replicas: 1
  selector:
    matchLabels:
      app: clickhouse
  template:
    metadata:
      labels:
        app: clickhouse
    spec:
      containers:
      - name: clickhouse
        image: clickhouse/clickhouse-server:25.3-alpine
        ports:
        - containerPort: 8123
          name: http
        - containerPort: 9000
          name: native
        env:
        - name: CLICKHOUSE_USER
          value: default
        - name: CLICKHOUSE_PASSWORD
          value: ""
        - name: CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT
          value: "1"
        resources:
          requests:
            memory: "1Gi"
            cpu: "200m"
          limits:
            memory: "4Gi"
        volumeMounts:
        - name: data
          mountPath: /var/lib/clickhouse
      volumes:
      - name: data
        emptyDir:
          sizeLimit: ${DATA_LIMIT}
---
apiVersion: v1
kind: Service
metadata:
  name: clickhouse
spec:
  type: NodePort
  selector:
    app: clickhouse
  ports:
  - name: native
    port: 9000
    targetPort: 9000
    nodePort: 30900
  - name: http
    port: 8123
    targetPort: 8123
CHEOF

  echo "  Waiting for ClickHouse to be ready..."
  sleep 5  # Wait for pod to be created before waiting on condition
  kubectl wait --for=condition=Ready pod -l app=clickhouse --timeout=120s
fi

# --- Step 3: Deploy OTel-to-ClickHouse bridge collector ---
echo "[3/5] Deploying OTel-to-ClickHouse bridge collector..."
if kubectl get deploy otel-clickhouse-bridge &>/dev/null; then
  echo "  Bridge collector already deployed, skipping."
else
  kubectl apply -f - <<'BREOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-clickhouse-bridge-config
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    exporters:
      clickhouse:
        endpoint: tcp://clickhouse.default.svc.cluster.local:9000?dial_timeout=10s
        database: default
        logs_table_name: otel_logs
        traces_table_name: otel_traces
        metrics_table_name: otel_metrics
        ttl: 72h
        timeout: 5s
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s
        create_schema: true
      debug:
        verbosity: basic
    service:
      pipelines:
        logs:
          receivers: [otlp]
          exporters: [clickhouse, debug]
        traces:
          receivers: [otlp]
          exporters: [clickhouse, debug]
        metrics:
          receivers: [otlp]
          exporters: [clickhouse, debug]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-clickhouse-bridge
  labels:
    app: otel-clickhouse-bridge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-clickhouse-bridge
  template:
    metadata:
      labels:
        app: otel-clickhouse-bridge
    spec:
      containers:
      - name: collector
        image: otel/opentelemetry-collector-contrib:0.114.0
        args: ["--config=/conf/config.yaml"]
        ports:
        - containerPort: 4317
          name: otlp-grpc
        - containerPort: 4318
          name: otlp-http
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "256Mi"
        volumeMounts:
        - name: config
          mountPath: /conf
      volumes:
      - name: config
        configMap:
          name: otel-clickhouse-bridge-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-clickhouse-bridge
spec:
  selector:
    app: otel-clickhouse-bridge
  ports:
  - name: otlp-grpc
    port: 4317
    targetPort: 4317
  - name: otlp-http
    port: 4318
    targetPort: 4318
BREOF

  echo "  Waiting for bridge collector to be ready..."
  sleep 5  # Wait for pod to be created before waiting on condition
  kubectl wait --for=condition=Ready pod -l app=otel-clickhouse-bridge --timeout=120s
fi

# --- Step 4: Deploy OpenTelemetry demo application ---
echo "[4/5] Deploying OpenTelemetry demo application..."
kubectl create namespace "${NAMESPACE}" 2>/dev/null || true

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update open-telemetry

BRIDGE_ENDPOINT="otel-clickhouse-bridge.default.svc.cluster.local"

if helm list -n "${NAMESPACE}" -q | grep -q "^otel-demo$"; then
  echo "  OTel demo already installed, skipping."
else
  # Install with heavy backends disabled; export telemetry to ClickHouse bridge
  helm install otel-demo open-telemetry/opentelemetry-demo \
    -n "${NAMESPACE}" \
    --set grafana.enabled=false \
    --set jaeger.enabled=false \
    --set prometheus.enabled=false \
    --set opensearch.enabled=false \
    --set components.llm.enabled=false \
    --set "opentelemetry-collector.config.exporters.otlp/clickhouse.endpoint=${BRIDGE_ENDPOINT}:4317" \
    --set "opentelemetry-collector.config.exporters.otlp/clickhouse.tls.insecure=true" \
    --set 'opentelemetry-collector.config.service.pipelines.logs.exporters={debug,otlp/clickhouse}' \
    --set 'opentelemetry-collector.config.service.pipelines.traces.exporters={debug,otlp/clickhouse,spanmetrics}' \
    --set 'opentelemetry-collector.config.service.pipelines.metrics.exporters={debug,otlp/clickhouse}' \
    --timeout 600s
fi

# --- Step 5: Wait for everything ---
echo "[5/5] Waiting for all pods to be ready..."
kubectl wait --for=condition=Ready pod -l app=clickhouse --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=Ready pod -l app=otel-clickhouse-bridge --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=Ready pod --all -n "${NAMESPACE}" --timeout=600s 2>/dev/null || true

echo ""
echo "=== Setup Complete ==="
echo ""
echo "ClickHouse native port: localhost:${HOST_CH_PORT} (via kind NodePort)"
echo ""
echo "To verify data ingestion (wait 2-3 minutes for data to flow):"
echo "  clickhouse client --port ${HOST_CH_PORT} --query 'SELECT count() FROM otel_logs'"
echo ""
echo "To port-forward ClickHouse (if NodePort not working):"
echo "  kubectl port-forward svc/clickhouse ${HOST_CH_PORT}:9000 &"
echo ""
echo "To use with SABRE:"
echo "  uv run sabre"
echo "  > use clickhouse integration"
echo "  > Investigate: <describe the issue>"
echo ""
