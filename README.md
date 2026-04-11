# SABRE ClickHouse Demo

A standalone demo environment for investigating Kubernetes incidents using [SABRE](https://github.com/sabre-ai/sabre-ai) with ClickHouse observability data.

Deploys a local kind cluster with the [OpenTelemetry Demo](https://opentelemetry.io/docs/demo/) application, standalone ClickHouse for storage, and feature flags for injecting anomalies.

## Prerequisites

- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/docs/intro/install/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [clickhouse client](https://clickhouse.com/docs/interfaces/cli) (`curl https://clickhouse.com/ | sh` or `brew install clickhouse`)
- [jq](https://jqlang.github.io/jq/download/) (for anomaly injection)
- [SABRE](https://github.com/sabre-ai/sabre-ai)
- Docker with at least 6GB memory allocated

## Quick Start

```bash
# 1. Deploy the demo environment
./setup.sh

# 2. Verify data is flowing (wait 2-3 minutes after setup)
clickhouse client --port 9000 --query "SELECT count() FROM otel_logs"

# 3. Inject an anomaly
./inject_anomaly.sh recommendationCacheFailure

# 4. Wait 5-10 minutes for telemetry to accumulate

# 5. Investigate with SABRE
uv run sabre
> use clickhouse integration
> Investigate: recommendation service is slow

# 6. Clean up when done
./clear_anomaly.sh   # Reset anomalies
./teardown.sh        # Delete kind cluster
```

## Available Anomalies

| Anomaly | Description | Difficulty |
|---------|-------------|------------|
| `recommendationCacheFailure` | Disables recommendation service cache, causing memory pressure and latency spikes | Medium |
| `paymentFailure` | Causes payment service to return errors for a percentage of transactions | Easy |
| `productCatalogFailure` | Makes product catalog service intermittently unavailable | Easy |
| `paymentCacheLeak` | Introduces a memory leak in the payment service cache | Hard |

## Using with SABRE

1. Start SABRE: `uv run sabre`
2. Say: `use clickhouse integration`
3. Describe the issue: `Investigate: recommendation service is responding slowly`
4. SABRE will query ClickHouse across logs, traces, and metrics to identify the root cause

The ClickHouse CLI integration teaches SABRE the OTel schema, SQL patterns, and investigation methodology for effective root cause analysis.

## Architecture

```
kind cluster (sabre-ch-demo)
├── ClickHouse (standalone, lightweight)
│   └── OTel tables: otel_logs, otel_traces, otel_metrics_*
├── OTel-to-ClickHouse Bridge (otel-collector-contrib)
│   └── Receives OTLP, writes to ClickHouse
├── OpenTelemetry Demo (Helm)
│   ├── Frontend, Cart, Checkout, Payment, ...
│   ├── OTel Collector → Bridge → ClickHouse
│   └── flagd (feature flags for anomaly injection)
└── kube-system (CoreDNS, etc.)
```

## Scripts

| Script | Description |
|--------|-------------|
| `setup.sh` | Create kind cluster, deploy ClickHouse + bridge + OTel demo |
| `inject_anomaly.sh <name>` | Enable a feature flag to inject an anomaly |
| `clear_anomaly.sh` | Disable all anomaly feature flags |
| `teardown.sh` | Delete the kind cluster |

## Troubleshooting

**No data in ClickHouse?**
- Check bridge collector logs: `kubectl logs deploy/otel-clickhouse-bridge`
- Check OTel demo collector logs: `kubectl logs -n otel-demo -l app.kubernetes.io/component=agent-collector`
- Verify ClickHouse is accessible: `kubectl port-forward svc/clickhouse 9000:9000 &`
- Verify tables exist: `clickhouse client --port 9000 --query "SHOW TABLES"`

**Anomaly not taking effect?**
- Ensure flagd restarted: `kubectl get pods -n otel-demo | grep flagd`
- Wait at least 5 minutes for telemetry to accumulate
- Verify flag state: `kubectl get configmap flagd-config -n otel-demo -o jsonpath='{.data.flags\.json}' | jq .`

**Resource pressure / pods crashing?**
- Ensure Docker has at least 6GB memory: Docker Desktop > Settings > Resources
- Scale down non-essential demo services: `kubectl scale deploy -n otel-demo ad fraud-detection image-provider product-reviews accounting email --replicas=0`

## License

Apache 2.0
