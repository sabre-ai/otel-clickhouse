#!/usr/bin/env bash
set -euo pipefail

# Seed realistic OTel anomaly data into ClickHouse for live demos.
# Inserts logs, traces, and metrics with now()-relative timestamps
# so data always looks fresh — no waiting for real telemetry.

ANOMALY="${1:-recommendationCacheFailure}"
CH="clickhouse client --port 19000"

AVAILABLE_ANOMALIES=(
  "recommendationCacheFailure"
  "paymentFailure"
  "productCatalogFailure"
  "paymentCacheLeak"
)

usage() {
  echo "Usage: $0 [anomaly_name]"
  echo ""
  echo "Available anomalies (default: recommendationCacheFailure):"
  for a in "${AVAILABLE_ANOMALIES[@]}"; do
    echo "  - $a"
  done
  exit 1
}

VALID=false
for a in "${AVAILABLE_ANOMALIES[@]}"; do
  [[ "$a" == "$ANOMALY" ]] && VALID=true && break
done
[[ "$VALID" != "true" ]] && echo "ERROR: Unknown anomaly '${ANOMALY}'" && usage

if ! $CH --query "SELECT 1" &>/dev/null; then
  echo "ERROR: Cannot connect to ClickHouse on port 19000."
  echo "  Is the demo deployed? Run ./setup.sh first."
  echo "  Or port-forward: kubectl port-forward svc/clickhouse 19000:9000 &"
  exit 1
fi

echo "=== Seeding data for anomaly: ${ANOMALY} ==="

TP="$(printf '%012x' $((RANDOM * RANDOM)))"

insert_log() {
  local mins="$1" sev="$2" svc="$3" body="$4" attrs="$5"
  echo "(now64(9) - INTERVAL ${mins} MINUTE, '${TP}$(printf '%04x' $RANDOM)', '$(printf '%04x' $RANDOM)', '${sev}', $([ "$sev" = "ERROR" ] && echo 17 || ([ "$sev" = "WARN" ] && echo 13 || echo 9)), '${svc}', '${body}', map('service.namespace','otel-demo'), ${attrs})"
}

insert_span() {
  local mins="$1" tid="$2" sid="$3" psid="$4" name="$5" svc="$6" dur_ms="$7" status="$8" msg="$9" attrs="${10}"
  echo "(now64(9) - INTERVAL ${mins} MINUTE, '${TP}${tid}', '${sid}', '${psid}', '${name}', 'SPAN_KIND_SERVER', '${svc}', ${dur_ms}000000, '${status}', '${msg}', ${attrs})"
}

insert_metric() {
  local mins="$1" svc="$2" name="$3" val="$4"
  echo "(map('service.name','${svc}'), '${name}', 'JVM heap memory usage', 'By', map('type','heap','pool','G1 Old Gen'), now64(9) - INTERVAL ${mins} MINUTE, ${val})"
}

run_inserts() {
  local table="$1"
  shift
  local vals=""
  for v in "$@"; do
    [[ -n "$vals" ]] && vals="${vals},"
    vals="${vals}${v}"
  done
  $CH --query "INSERT INTO ${table} VALUES ${vals}"
}

# ------------------------------------------------------------------
seed_recommendationCacheFailure() {
  echo "  Inserting logs..."
  local logs=()
  for i in $(seq 1 15); do logs+=("$(insert_log $((i*2)) INFO frontend 'GET /api/products 200 OK' "map('http.method','GET')")"); done
  for i in $(seq 1 10); do logs+=("$(insert_log $((i*2)) INFO payment 'Payment processed successfully' "map('payment.method','credit_card')")"); done
  for i in $(seq 1 8); do logs+=("$(insert_log $((i*3)) INFO checkout 'Order placed successfully' "map('order.status','completed')")"); done
  for i in $(seq 1 8); do logs+=("$(insert_log $((30-i*3)) WARN recommendation 'Cache miss for product recommendations - falling back to direct query' "map('cache.hit','false')")"); done
  for i in $(seq 1 12); do logs+=("$(insert_log $((24-i*2)) ERROR recommendation 'java.lang.OutOfMemoryError: Java heap space - GC overhead limit exceeded' "map('exception.type','java.lang.OutOfMemoryError')")"); done
  for i in $(seq 1 6); do logs+=("$(insert_log $((12-i*2)) ERROR recommendation 'Connection timeout to product-catalog service after 5000ms' "map('error.kind','timeout')")"); done
  for i in $(seq 1 5); do logs+=("$(insert_log $((10-i*2)) WARN frontend 'GET /api/recommendations 504 Gateway Timeout' "map('http.method','GET','http.status_code','504')")"); done
  run_inserts "otel_logs (Timestamp, TraceId, SpanId, SeverityText, SeverityNumber, ServiceName, Body, ResourceAttributes, LogAttributes)" "${logs[@]}"

  echo "  Inserting traces..."
  local spans=()
  for i in $(seq 1 10); do
    spans+=("$(insert_span $((i*3)) "h${i}a" "hs${i}1" "" "GET /api/products" frontend $((150+RANDOM%100)) STATUS_CODE_OK "" "map('http.method','GET','http.status_code','200')")")
    spans+=("$(insert_span $((i*3)) "h${i}a" "hs${i}2" "hs${i}1" "GetProduct" product-catalog $((50+RANDOM%50)) STATUS_CODE_OK "" "map('rpc.method','GetProduct')")")
    spans+=("$(insert_span $((i*3)) "h${i}b" "hs${i}3" "" "POST /api/checkout" checkout $((300+RANDOM%200)) STATUS_CODE_OK "" "map('http.method','POST')")")
    spans+=("$(insert_span $((i*3)) "h${i}b" "hs${i}4" "hs${i}3" "Charge" payment $((80+RANDOM%60)) STATUS_CODE_OK "" "map('rpc.method','Charge')")")
  done
  for i in $(seq 1 5); do
    local lat=$((200+i*300))
    spans+=("$(insert_span $((28-i*2)) "r${i}a" "rs${i}1" "" "GET /api/recommendations" frontend $lat STATUS_CODE_OK "" "map('http.method','GET','http.status_code','200')")")
    spans+=("$(insert_span $((28-i*2)) "r${i}a" "rs${i}2" "rs${i}1" "ListRecommendations" recommendation $((lat-50)) STATUS_CODE_OK "" "map('rpc.method','ListRecommendations')")")
  done
  for i in $(seq 1 8); do
    local lat=$((5000+i*500))
    spans+=("$(insert_span $((18-i*2)) "e${i}a" "re${i}1" "" "GET /api/recommendations" frontend $lat STATUS_CODE_ERROR "upstream timeout" "map('http.method','GET','http.status_code','504')")")
    spans+=("$(insert_span $((18-i*2)) "e${i}a" "re${i}2" "re${i}1" "ListRecommendations" recommendation $((lat-100)) STATUS_CODE_ERROR "java.lang.OutOfMemoryError" "map('rpc.method','ListRecommendations')")")
  done
  run_inserts "otel_traces (Timestamp, TraceId, SpanId, ParentSpanId, SpanName, SpanKind, ServiceName, Duration, StatusCode, StatusMessage, SpanAttributes)" "${spans[@]}"
  $CH --query "INSERT INTO otel_traces_trace_id_ts SELECT * FROM otel_traces WHERE Timestamp >= now() - INTERVAL 1 HOUR"

  echo "  Inserting metrics..."
  local metrics=()
  for i in $(seq 1 10); do metrics+=("$(insert_metric $((30-i*3)) recommendation process.runtime.jvm.memory.usage $((268435456+i*80530636)))"); done
  for i in $(seq 1 5); do
    metrics+=("$(insert_metric $((i*5)) frontend process.runtime.jvm.memory.usage $((134217728+RANDOM%10000000)))")
    metrics+=("$(insert_metric $((i*5)) payment process.runtime.jvm.memory.usage $((67108864+RANDOM%5000000)))")
    metrics+=("$(insert_metric $((i*5)) checkout process.runtime.jvm.memory.usage $((100663296+RANDOM%8000000)))")
  done
  run_inserts "otel_metrics_gauge (ResourceAttributes, MetricName, MetricDescription, MetricUnit, Attributes, TimeUnix, Value)" "${metrics[@]}"
}

# ------------------------------------------------------------------
seed_paymentFailure() {
  echo "  Inserting logs..."
  local logs=()
  for i in $(seq 1 10); do
    logs+=("$(insert_log $((i*2)) INFO frontend 'GET /api/products 200 OK' "map('http.method','GET')")")
    logs+=("$(insert_log $((i*2)) INFO recommendation 'ListRecommendations completed in 180ms' "map('rpc.method','ListRecommendations')")")
  done
  for i in $(seq 1 15); do logs+=("$(insert_log $((i*2)) ERROR payment 'Charge failed: payment gateway returned HTTP 500' "map('rpc.method','Charge','error.kind','payment_gateway_error')")"); done
  for i in $(seq 1 5); do logs+=("$(insert_log $((i*3)) ERROR checkout 'Order checkout failed: payment service returned error' "map('order.status','failed')")"); done
  run_inserts "otel_logs (Timestamp, TraceId, SpanId, SeverityText, SeverityNumber, ServiceName, Body, ResourceAttributes, LogAttributes)" "${logs[@]}"

  echo "  Inserting traces..."
  local spans=()
  for i in $(seq 1 8); do spans+=("$(insert_span $((i*3)) "h${i}a" "hs${i}1" "" "GET /api/products" frontend $((150+RANDOM%100)) STATUS_CODE_OK "" "map('http.method','GET','http.status_code','200')")"); done
  for i in $(seq 1 12); do
    spans+=("$(insert_span $((i*2)) "pf${i}" "pf${i}1" "" "POST /api/checkout" checkout $((800+RANDOM%400)) STATUS_CODE_ERROR "payment failed" "map('http.method','POST','http.status_code','500')")")
    spans+=("$(insert_span $((i*2)) "pf${i}" "pf${i}2" "pf${i}1" "Charge" payment $((600+RANDOM%300)) STATUS_CODE_ERROR "payment gateway HTTP 500" "map('rpc.method','Charge')")")
  done
  run_inserts "otel_traces (Timestamp, TraceId, SpanId, ParentSpanId, SpanName, SpanKind, ServiceName, Duration, StatusCode, StatusMessage, SpanAttributes)" "${spans[@]}"
  $CH --query "INSERT INTO otel_traces_trace_id_ts SELECT * FROM otel_traces WHERE Timestamp >= now() - INTERVAL 1 HOUR"

  echo "  Inserting metrics..."
  local metrics=()
  for i in $(seq 1 8); do
    metrics+=("$(insert_metric $((i*3)) payment process.runtime.jvm.memory.usage $((134217728+RANDOM%10000000)))")
    metrics+=("$(insert_metric $((i*3)) frontend process.runtime.jvm.memory.usage $((134217728+RANDOM%10000000)))")
  done
  run_inserts "otel_metrics_gauge (ResourceAttributes, MetricName, MetricDescription, MetricUnit, Attributes, TimeUnix, Value)" "${metrics[@]}"
}

# ------------------------------------------------------------------
seed_productCatalogFailure() {
  echo "  Inserting logs..."
  local logs=()
  for i in $(seq 1 10); do
    logs+=("$(insert_log $((i*2)) ERROR product-catalog 'Failed to serve request: connection refused to upstream' "map('error.kind','connection_refused')")")
    logs+=("$(insert_log $((i*2+1)) INFO product-catalog 'GetProduct completed successfully' "map('rpc.method','GetProduct')")")
  done
  for i in $(seq 1 8); do logs+=("$(insert_log $((i*3)) ERROR frontend 'GET /api/products 503 Service Unavailable' "map('http.method','GET','http.status_code','503')")"); done
  run_inserts "otel_logs (Timestamp, TraceId, SpanId, SeverityText, SeverityNumber, ServiceName, Body, ResourceAttributes, LogAttributes)" "${logs[@]}"

  echo "  Inserting traces..."
  local spans=()
  for i in $(seq 1 10); do
    spans+=("$(insert_span $((i*2)) "pcf${i}" "pcf${i}1" "" "GET /api/products" frontend $((3000+RANDOM%500)) STATUS_CODE_ERROR "upstream unavailable" "map('http.method','GET','http.status_code','503')")")
    spans+=("$(insert_span $((i*2)) "pcf${i}" "pcf${i}2" "pcf${i}1" "GetProduct" product-catalog $((2800+RANDOM%400)) STATUS_CODE_ERROR "connection refused" "map('rpc.method','GetProduct')")")
    spans+=("$(insert_span $((i*2+1)) "pcs${i}" "pcs${i}1" "" "GET /api/products" frontend $((150+RANDOM%100)) STATUS_CODE_OK "" "map('http.method','GET','http.status_code','200')")")
    spans+=("$(insert_span $((i*2+1)) "pcs${i}" "pcs${i}2" "pcs${i}1" "GetProduct" product-catalog $((50+RANDOM%50)) STATUS_CODE_OK "" "map('rpc.method','GetProduct')")")
  done
  run_inserts "otel_traces (Timestamp, TraceId, SpanId, ParentSpanId, SpanName, SpanKind, ServiceName, Duration, StatusCode, StatusMessage, SpanAttributes)" "${spans[@]}"
  $CH --query "INSERT INTO otel_traces_trace_id_ts SELECT * FROM otel_traces WHERE Timestamp >= now() - INTERVAL 1 HOUR"

  echo "  Inserting metrics..."
  local metrics=()
  for i in $(seq 1 8); do
    metrics+=("$(insert_metric $((i*3)) product-catalog process.runtime.jvm.memory.usage $((134217728+RANDOM%10000000)))")
    metrics+=("$(insert_metric $((i*3)) frontend process.runtime.jvm.memory.usage $((134217728+RANDOM%10000000)))")
  done
  run_inserts "otel_metrics_gauge (ResourceAttributes, MetricName, MetricDescription, MetricUnit, Attributes, TimeUnix, Value)" "${metrics[@]}"
}

# ------------------------------------------------------------------
seed_paymentCacheLeak() {
  echo "  Inserting logs..."
  local logs=()
  for i in $(seq 1 10); do logs+=("$(insert_log $((i*3)) INFO frontend 'GET /api/products 200 OK' "map('http.method','GET')")"); done
  for i in $(seq 1 6); do logs+=("$(insert_log $((30-i*4)) WARN payment "GC pause exceeded threshold: ${i}${i}0ms (limit: 200ms)" "map('gc.pause_ms','${i}${i}0')")"); done
  for i in $(seq 1 8); do logs+=("$(insert_log $((12-i)) WARN payment "Cache size growing: $((10000+i*5000)) entries, memory pressure increasing" "map('cache.size','$((10000+i*5000))')")"); done
  for i in $(seq 1 4); do logs+=("$(insert_log $((4-i)) ERROR payment 'java.lang.OutOfMemoryError: Java heap space during transaction processing' "map('exception.type','java.lang.OutOfMemoryError')")"); done
  run_inserts "otel_logs (Timestamp, TraceId, SpanId, SeverityText, SeverityNumber, ServiceName, Body, ResourceAttributes, LogAttributes)" "${logs[@]}"

  echo "  Inserting traces..."
  local spans=()
  for i in $(seq 1 10); do
    local lat=$((100+i*80))
    local st="STATUS_CODE_OK" msg=""
    [[ $i -gt 7 ]] && st="STATUS_CODE_ERROR" && msg="OutOfMemoryError"
    spans+=("$(insert_span $((30-i*3)) "pl${i}" "pl${i}1" "" "POST /api/checkout" checkout $((lat+100)) "$st" "$msg" "map('http.method','POST')")")
    spans+=("$(insert_span $((30-i*3)) "pl${i}" "pl${i}2" "pl${i}1" "Charge" payment $lat "$st" "$msg" "map('rpc.method','Charge')")")
  done
  run_inserts "otel_traces (Timestamp, TraceId, SpanId, ParentSpanId, SpanName, SpanKind, ServiceName, Duration, StatusCode, StatusMessage, SpanAttributes)" "${spans[@]}"
  $CH --query "INSERT INTO otel_traces_trace_id_ts SELECT * FROM otel_traces WHERE Timestamp >= now() - INTERVAL 1 HOUR"

  echo "  Inserting metrics..."
  local metrics=()
  for i in $(seq 1 10); do metrics+=("$(insert_metric $((30-i*3)) payment process.runtime.jvm.memory.usage $((134217728+i*94371840)))"); done
  for i in $(seq 1 5); do
    metrics+=("$(insert_metric $((i*5)) frontend process.runtime.jvm.memory.usage $((134217728+RANDOM%10000000)))")
    metrics+=("$(insert_metric $((i*5)) recommendation process.runtime.jvm.memory.usage $((201326592+RANDOM%10000000)))")
  done
  run_inserts "otel_metrics_gauge (ResourceAttributes, MetricName, MetricDescription, MetricUnit, Attributes, TimeUnix, Value)" "${metrics[@]}"
}

# Dispatch
"seed_${ANOMALY}"

# Summary
echo ""
echo "=== Seed Complete ==="
LOGS=$($CH --query "SELECT count() FROM otel_logs WHERE Timestamp >= now() - INTERVAL 1 HOUR")
TRACES=$($CH --query "SELECT count() FROM otel_traces WHERE Timestamp >= now() - INTERVAL 1 HOUR")
METRICS=$($CH --query "SELECT count() FROM otel_metrics_gauge WHERE TimeUnix >= now() - INTERVAL 1 HOUR")
echo "  Logs:    ${LOGS} rows"
echo "  Traces:  ${TRACES} rows"
echo "  Metrics: ${METRICS} rows"
echo ""
echo "Ready for SABRE investigation. No waiting needed."
