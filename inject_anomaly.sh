#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="otel-demo"

AVAILABLE_ANOMALIES=(
  "recommendationCacheFailure"
  "paymentFailure"
  "productCatalogFailure"
  "paymentCacheLeak"
)

usage() {
  echo "Usage: $0 <anomaly_name>"
  echo ""
  echo "Available anomalies:"
  for a in "${AVAILABLE_ANOMALIES[@]}"; do
    echo "  - $a"
  done
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
fi

ANOMALY="$1"

# Validate anomaly name
VALID=false
for a in "${AVAILABLE_ANOMALIES[@]}"; do
  if [[ "$a" == "$ANOMALY" ]]; then
    VALID=true
    break
  fi
done

if [[ "$VALID" != "true" ]]; then
  echo "ERROR: Unknown anomaly '${ANOMALY}'"
  echo ""
  usage
fi

echo "=== Injecting anomaly: ${ANOMALY} ==="

# Patch flagd ConfigMap to enable the feature flag
kubectl get configmap flagd-config -n "${NAMESPACE}" -o json \
  | jq --arg flag "$ANOMALY" '
    .data["flags.json"] = (
      .data["flags.json"] | fromjson
      | .flags[$flag].state = "ENABLED"
      | .flags[$flag].defaultVariant = "on"
      | tojson
    )
  ' \
  | kubectl apply -f -

# Restart flagd to pick up changes
kubectl rollout restart deployment/flagd -n "${NAMESPACE}" 2>/dev/null \
  || kubectl rollout restart deployment/otel-demo-flagd -n "${NAMESPACE}" 2>/dev/null \
  || echo "WARNING: Could not find flagd deployment. You may need to restart it manually."

echo ""
echo "Anomaly '${ANOMALY}' injected."
echo "Wait 5-10 minutes for telemetry to accumulate, then investigate with SABRE."
