#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="sabre-ch-demo"
ECOMMERCE_REPO="https://github.com/sabre-ai/ecommerce.git"
ECOMMERCE_DIR="/tmp/sabre-ecommerce"

echo "=== SABRE ClickHouse Demo Setup ==="
echo ""

# --- Pre-flight checks ---
for cmd in kubectl kind docker git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed."
    exit 1
  fi
done

# Check port 9000 is available (ClickHouse native protocol)
if lsof -i :9000 -P -n 2>/dev/null | grep -q LISTEN; then
  echo "ERROR: Port 9000 is already in use."
  echo "  Check what's using it: lsof -i :9000"
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
        hostPort: 9000
        protocol: TCP
EOF
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

# --- Pre-pull heavy images into kind node ---
echo "Pre-pulling container images into kind node..."
docker pull clickhouse/clickhouse-server:25.3-alpine
docker pull otel/opentelemetry-collector-contrib:0.114.0
kind load docker-image clickhouse/clickhouse-server:25.3-alpine otel/opentelemetry-collector-contrib:0.114.0 --name "${CLUSTER_NAME}"

# --- Step 2: Deploy standalone ClickHouse ---
echo "[2/5] Deploying ClickHouse..."
if kubectl get deploy clickhouse &>/dev/null; then
  echo "  ClickHouse already deployed, skipping."
else
  # OTel tables are created automatically by the bridge collector (create_schema: true)
  kubectl apply -f - <<'CHEOF'
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
        emptyDir: {}
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
  until kubectl get pod -l app=clickhouse -o name 2>/dev/null | grep -q .; do
    sleep 2
  done
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
  until kubectl get pod -l app=otel-clickhouse-bridge -o name 2>/dev/null | grep -q .; do
    sleep 2
  done
  kubectl wait --for=condition=Ready pod -l app=otel-clickhouse-bridge --timeout=120s
fi

# --- Step 4: Deploy ecommerce application ---
echo "[4/5] Deploying ecommerce application..."

# Clone or update the ecommerce repo
if [[ -d "${ECOMMERCE_DIR}/.git" ]]; then
  echo "  Updating ecommerce repo..."
  git -C "${ECOMMERCE_DIR}" pull --ff-only
else
  echo "  Cloning ecommerce repo..."
  rm -rf "${ECOMMERCE_DIR}"
  git clone "${ECOMMERCE_REPO}" "${ECOMMERCE_DIR}"
fi

# Build and load the backend Docker image
echo "  Building ecommerce-api Docker image..."
docker build -t ecommerce-api:latest "${ECOMMERCE_DIR}/backend"
kind load docker-image ecommerce-api:latest --name "${CLUSTER_NAME}"

# Create namespace and deploy
kubectl create namespace ecommerce 2>/dev/null || true

kubectl create configmap nginx-config -n ecommerce \
  --from-file=default.conf="${ECOMMERCE_DIR}/nginx.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${ECOMMERCE_DIR}/deployment.yaml"

echo "  Waiting for ecommerce pods to be ready..."
kubectl wait --for=condition=Ready pod -l app=ecommerce-api -n ecommerce --timeout=120s
kubectl wait --for=condition=Ready pod -l app=load-generator -n ecommerce --timeout=120s 2>/dev/null || true

# --- Step 5: Verify data flow ---
echo "[5/5] Waiting for telemetry data to flow..."
kubectl wait --for=condition=Ready pod -l app=clickhouse --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=Ready pod -l app=otel-clickhouse-bridge --timeout=120s 2>/dev/null || true

# Wait for some data to appear in ClickHouse
echo "  Waiting for ecommerce telemetry in ClickHouse (up to 2 minutes)..."
for i in $(seq 1 24); do
  COUNT=$(clickhouse client --port 9000 --query "SELECT count() FROM otel_logs WHERE ServiceName = 'ecommerce-api'" 2>/dev/null || echo 0)
  if [[ "$COUNT" -gt 0 ]]; then
    echo "  Found ${COUNT} log rows from ecommerce-api."
    break
  fi
  sleep 5
done

echo ""
echo "=== Setup Complete ==="
echo ""
echo "ClickHouse native port: localhost:9000 (via kind NodePort)"
echo ""
echo "Running pods:"
kubectl get pods -n ecommerce --no-headers 2>/dev/null | sed 's/^/  /'
echo ""
echo "To verify data:"
echo "  clickhouse client --query \"SELECT SeverityText, count() FROM otel_logs WHERE ServiceName='ecommerce-api' GROUP BY SeverityText\""
echo ""
echo "To use with SABRE:"
echo "  sabre"
echo "  > The ecommerce-api service is showing checkout failures. Use the otel tables"
echo "  >   in clickhouse to investigate errors with stack traces. The source code is"
echo "  >   at github.com/sabre-ai/ecommerce"
echo ""
