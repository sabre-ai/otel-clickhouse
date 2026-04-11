#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="sabre-ch-demo"
NAMESPACE="otel-demo"

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

# --- Step 2: Deploy standalone ClickHouse ---
echo "[2/5] Deploying ClickHouse..."
if kubectl get deploy clickhouse &>/dev/null; then
  echo "  ClickHouse already deployed, skipping."
else
  kubectl apply -f - <<'CHEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: clickhouse-init
data:
  01_logs.sql: |
    CREATE TABLE IF NOT EXISTS otel_logs (
        Timestamp DateTime64(9),
        TraceId String,
        SpanId String,
        TraceFlags UInt32,
        SeverityText LowCardinality(String),
        SeverityNumber Int32,
        ServiceName LowCardinality(String),
        Body String,
        ResourceSchemaUrl String,
        ResourceAttributes Map(LowCardinality(String), String),
        ScopeSchemaUrl String,
        ScopeName String,
        ScopeVersion String,
        ScopeAttributes Map(LowCardinality(String), String),
        LogAttributes Map(LowCardinality(String), String)
    ) ENGINE = MergeTree()
    ORDER BY (ServiceName, Timestamp)
    TTL toDateTime(Timestamp) + INTERVAL 3 DAY;
  02_traces.sql: |
    CREATE TABLE IF NOT EXISTS otel_traces (
        Timestamp DateTime64(9),
        TraceId String,
        SpanId String,
        ParentSpanId String,
        TraceState String,
        SpanName LowCardinality(String),
        SpanKind LowCardinality(String),
        ServiceName LowCardinality(String),
        ResourceAttributes Map(LowCardinality(String), String),
        ScopeName String,
        ScopeVersion String,
        SpanAttributes Map(LowCardinality(String), String),
        Duration Int64,
        StatusCode LowCardinality(String),
        StatusMessage String
    ) ENGINE = MergeTree()
    ORDER BY (ServiceName, Timestamp)
    TTL toDateTime(Timestamp) + INTERVAL 3 DAY;
  03_traces_ts.sql: |
    CREATE TABLE IF NOT EXISTS otel_traces_trace_id_ts AS otel_traces;
  04_metrics_gauge.sql: |
    CREATE TABLE IF NOT EXISTS otel_metrics_gauge (
        ResourceAttributes Map(LowCardinality(String), String),
        ResourceSchemaUrl String,
        ScopeName String,
        ScopeVersion String,
        ScopeAttributes Map(LowCardinality(String), String),
        ScopeSchemaUrl String,
        MetricName LowCardinality(String),
        MetricDescription String,
        MetricUnit String,
        Attributes Map(LowCardinality(String), String),
        StartTimeUnix DateTime64(9),
        TimeUnix DateTime64(9),
        Value Float64,
        Flags UInt32
    ) ENGINE = MergeTree()
    ORDER BY (MetricName, TimeUnix)
    TTL toDateTime(TimeUnix) + INTERVAL 3 DAY;
  05_metrics_sum.sql: |
    CREATE TABLE IF NOT EXISTS otel_metrics_sum (
        ResourceAttributes Map(LowCardinality(String), String),
        ResourceSchemaUrl String,
        ScopeName String,
        ScopeVersion String,
        ScopeAttributes Map(LowCardinality(String), String),
        ScopeSchemaUrl String,
        MetricName LowCardinality(String),
        MetricDescription String,
        MetricUnit String,
        Attributes Map(LowCardinality(String), String),
        StartTimeUnix DateTime64(9),
        TimeUnix DateTime64(9),
        Value Float64,
        Flags UInt32,
        AggTemp Int32,
        IsMonotonic Bool
    ) ENGINE = MergeTree()
    ORDER BY (MetricName, TimeUnix)
    TTL toDateTime(TimeUnix) + INTERVAL 3 DAY;
  06_metrics_histogram.sql: |
    CREATE TABLE IF NOT EXISTS otel_metrics_histogram (
        ResourceAttributes Map(LowCardinality(String), String),
        ResourceSchemaUrl String,
        ScopeName String,
        ScopeVersion String,
        ScopeAttributes Map(LowCardinality(String), String),
        ScopeSchemaUrl String,
        MetricName LowCardinality(String),
        MetricDescription String,
        MetricUnit String,
        Attributes Map(LowCardinality(String), String),
        StartTimeUnix DateTime64(9),
        TimeUnix DateTime64(9),
        Count UInt64,
        Sum Float64,
        BucketCounts Array(UInt64),
        ExplicitBounds Array(Float64),
        Min Float64,
        Max Float64,
        Flags UInt32,
        AggTemp Int32
    ) ENGINE = MergeTree()
    ORDER BY (MetricName, TimeUnix)
    TTL toDateTime(TimeUnix) + INTERVAL 3 DAY;
---
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
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "2Gi"
        volumeMounts:
        - name: data
          mountPath: /var/lib/clickhouse
        - name: init-sql
          mountPath: /docker-entrypoint-initdb.d
      volumes:
      - name: data
        emptyDir: {}
      - name: init-sql
        configMap:
          name: clickhouse-init
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
        create_schema: false
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
echo "ClickHouse native port: localhost:9000 (via kind NodePort)"
echo ""
echo "To verify data ingestion (wait 2-3 minutes for data to flow):"
echo "  clickhouse client --port 9000 --query 'SELECT count() FROM otel_logs'"
echo ""
echo "To port-forward ClickHouse (if NodePort not working):"
echo "  kubectl port-forward svc/clickhouse 9000:9000 &"
echo ""
echo "To use with SABRE:"
echo "  uv run sabre"
echo "  > use clickhouse integration"
echo "  > Investigate: <describe the issue>"
echo ""
