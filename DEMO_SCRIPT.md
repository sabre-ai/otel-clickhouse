# SABRE + ClickHouse Demo: AI-Powered Root Cause Analysis

## Video Title
**"From Incident to Root Cause in Under 3 Minutes — SABRE x ClickHouse"**

---

# Part 1: Pre-Warming the Demo

Do this 15-20 minutes before the meeting/recording.

### Step 1: Deploy everything

```bash
cd sabre-ch-demo
./setup.sh
```

Creates a kind cluster with:
- Standalone ClickHouse (stores OTel data)
- OTel Collector bridge (receives OTLP, writes to ClickHouse)
- OpenTelemetry Demo app (16 microservices generating real telemetry)

### Step 2: Wait for data to accumulate

Wait 10-15 minutes. Verify:

```bash
clickhouse client --port 9000 --query "SELECT 'logs', count() FROM otel_logs UNION ALL SELECT 'traces', count() FROM otel_traces"
```

Both counts should be in the thousands.

### Step 3: Scale down for stability

```bash
kubectl scale deploy -n otel-demo \
  kafka fraud-detection accounting ad image-provider product-reviews email quote \
  --replicas=0
```

ClickHouse retains all collected data. This frees memory so queries stay fast during the demo.

### Step 4: Verify SABRE works

```bash
sabre --cloud
> use clickhouse integration
```

Confirm it loads, then exit.

### Step 5: Verify there's interesting data

```bash
clickhouse client --port 9000 --query "
SELECT ServiceName, round(quantile(0.95)(Duration/1e6)) AS p95_ms
FROM otel_traces WHERE Timestamp BETWEEN '2026-04-12 19:15:00' AND '2026-04-12 19:40:00'
GROUP BY ServiceName ORDER BY p95_ms DESC LIMIT 5"
```

You should see accounting at ~40,000ms p95.

### If something goes wrong

```bash
# Re-establish port-forward if queries hang
pkill -f "kubectl port-forward svc/clickhouse"; sleep 1
kubectl port-forward svc/clickhouse 9000:9000 &

# Nuclear option
./teardown.sh && ./setup.sh
```

---

# Part 2: The Presentation

Total runtime: ~6-7 minutes

---

## SCENE 1: Introduction — What is SABRE (60 seconds)

### On Screen
Slide or terminal, your choice.

### Say

> "Let me introduce SABRE — an open-source AI agent for operations."
>
> "The key problem we solve: today, if you want to use AI for incident investigation, you need frontier models like GPT-4o or Claude — expensive, cloud-only, and you're sending your production data to a third-party API."
>
> "SABRE takes a different approach. We achieve frontier-model performance for observability tasks using open-source models — models you can run on-prem, in air-gapped environments, behind your firewall."
>
> "How? It comes down to architecture."

---

## SCENE 2: SABRE Architecture — No Capability Cliff (60 seconds)

### On Screen
Architecture diagram or whiteboard:

```
User: "Investigate the accounting service"
         |
    [ SABRE Agent ]
         |
    Generates <helpers> code blocks
         |
    ┌────┴────┐────────┐────────┐
    │         │        │        │
 ClickHouse  kubectl  GitHub   LLM
 (queries)   (logs)   (code)   (sub-tasks)
    │         │        │        │
    └────┬────┘────────┘────────┘
         |
    Results injected back
         |
    Analyzes → generates more code → iterates
         |
    Root cause with evidence
```

### Say

> "Most AI tools work like this: you paste your logs into a chatbot, the model reads them, gives you generic advice. That's a one-shot prompt. When the problem is complex, the model hits a capability cliff — it can't query more data, can't check the source code, can't iterate."
>
> "SABRE has no capability cliff. Instead of one-shot prompting, SABRE generates executable code in helpers blocks. It writes ClickHouse SQL, runs kubectl commands, clones GitHub repos — whatever the investigation requires. Then it reads the results, decides what to do next, and iterates."
>
> "This is why we can use smaller, cheaper models and still get frontier-level results. The intelligence isn't just in the model — it's in the investigation loop. The model doesn't need to be brilliant. It needs to follow a methodology, execute queries, and reason about results. SABRE's architecture makes that possible."

---

## SCENE 3: Demo Setup (30 seconds)

### On Screen
Terminal showing the cluster.

### Say

> "Let me show you what this looks like in practice."
>
> "I have the OpenTelemetry demo application running on a local Kubernetes cluster — 16 microservices generating real telemetry. All of it flowing into ClickHouse through an OpenTelemetry Collector pipeline: logs, traces, and metrics."
>
> "In this demo, SABRE will use three integrations together: ClickHouse for querying observability data, kubectl for checking pod logs, and GitHub for reading source code. All driven by the same investigation loop."

---

## SCENE 4: Start the Investigation (15 seconds)

### Type

```
sabre
```

Wait for connection, then type:

```
use clickhouse integration
```

Pause while it loads. Then type:

```
We had performance issues around 19:15 to 19:40 UTC yesterday. Investigate which services had the highest latency and error rates.
```

### Say

> "I'm describing the incident in plain English. SABRE will now investigate autonomously."

---

## SCENE 5: SABRE Investigates — TRIAGE (60 seconds)

### What the audience sees

SABRE generates helpers blocks with ClickHouse SQL:

```python
query = """
SELECT ServiceName,
  countIf(SeverityText IN ('ERROR','Error','error')) AS errors, count() AS total
FROM otel_logs
WHERE Timestamp >= '2026-04-12 19:15:00' AND Timestamp <= '2026-04-12 19:40:00'
GROUP BY ServiceName ORDER BY errors DESC LIMIT 15
"""
Bash.execute(f'clickhouse client --query "{query}"')
```

Results show accounting at 26 errors, 40,597ms p95 latency.

### Say

> "Look at what's happening. SABRE wrote a ClickHouse SQL query, executed it, and got back results from real production data."
>
> "You can see the exact SQL in the helpers block — every query is visible, every step is auditable. This isn't a black box."
>
> "The accounting service jumps out immediately — 26 errors and 40-second p95 latency. Everything else is under 2 seconds. Let's drill in."

---

## SCENE 6: DRILL — Error Details (45 seconds)

### Type

```
Drill down into accounting service. Look for errors including exception stack traces.
```

### What the audience sees

SABRE runs two queries:
1. Error messages grouped by Body → finds "Order parsing failed: 26 occurrences"
2. Exception stack traces from LogAttributes → finds `DbUpdateException: duplicate key value violates unique constraint "order_pkey"` with full Postgres stack trace pointing to `Consumer.cs:line 132`

### Say

> "SABRE is now drilling into the accounting service. First it pulls the error messages — 'Order parsing failed' 26 times."
>
> "Then — and this is important — it automatically queries the exception stack traces from the log attributes. It knows that in OpenTelemetry, exception details are stored in LogAttributes, not in the log body. That's the domain knowledge baked into the integration."
>
> "And there's the smoking gun: a Postgres duplicate key constraint violation on the order table, at Consumer.cs line 132. We now know WHAT is failing. Let's find out WHY."

---

## SCENE 7: Source Code Analysis (45 seconds)

### Type

```
Look at the source code in github repo open-telemetry/opentelemetry-demo at src/accounting. What is causing the duplicate key constraint violation?
```

### What the audience sees

SABRE clones the repo, reads Consumer.cs and Entities.cs, identifies that `ProcessMessage` creates an `OrderEntity` with `Id = order.OrderId` and calls `dbContext.SaveChanges()` — if the same orderId arrives twice, the INSERT violates the unique constraint.

### Say

> "Now watch — SABRE is cloning the actual GitHub repository, reading the source code, and correlating it with the exception we found in ClickHouse."
>
> "It found the issue: the ProcessMessage method creates an order entity using the orderId from Kafka and inserts it directly into PostgreSQL. There's no check for duplicates. If the same order arrives twice, the database rejects it with a constraint violation."
>
> "But why would the same order arrive twice? Let's ask."

---

## SCENE 8: Root Cause (30 seconds)

### Type

```
Look at the Kafka consumer configuration in Consumer.cs. Why would the same orderId be consumed twice? What is the fix?
```

### What the audience sees

SABRE identifies `EnableAutoCommit = true` and `AutoOffsetReset.Earliest` — explains that on consumer rebalancing (pod restart, scaling), uncommitted offsets are lost and messages get re-delivered. Recommends disabling auto-commit or adding an idempotency check.

### Say

> "And there's the root cause. The Kafka consumer uses auto-commit — offsets are committed on a timer, not after successful processing. When the pod restarts, uncommitted offsets are lost, messages get re-delivered, and the same order gets inserted twice."
>
> "SABRE went from a vague incident report to a specific code-level root cause: ClickHouse metrics, to error logs, to exception stack traces, to GitHub source code, to Kafka configuration. Four data sources, one investigation."

---

## SCENE 9: Takeaway (60 seconds)

### Say

> "Let me highlight what just happened."
>
> "First — this was gpt-4o-mini. Not GPT-4o, not Claude Opus. A small, cheap model. SABRE's architecture — the helpers loop, the domain integrations, the investigation methodology — that's what delivered frontier-level root cause analysis. Not model size."
>
> "Second — every step was transparent. You saw the SQL queries, the kubectl commands, the git clone. An SRE can verify every claim SABRE makes. This is auditable AI."
>
> "Third — this runs anywhere. SABRE works with open-source models. You can run it on-prem, air-gapped, behind your firewall. Your production data never leaves your infrastructure."
>
> "And fourth — the integrations compose. ClickHouse for observability data, kubectl for pod logs, GitHub for source code. SABRE used all three together in one investigation because the helpers loop lets the model reach for whatever tool it needs. There's no capability cliff."
>
> "The cost implication is significant. Frontier models cost 10-30x more per token than models like gpt-4o-mini or open-source alternatives. If you can get the same investigation quality from a cheaper model by pairing it with the right architecture, that changes the economics of AI-powered operations."

---

## SCENE 10: Close (10 seconds)

### Say

> "SABRE plus ClickHouse. Open-source models, frontier-level observability. From incident to root cause in under 3 minutes."

---

## Total Runtime: ~6-7 minutes

---

## Presentation Notes

**Key messages to land:**
- "Open-source models, frontier performance" — say this multiple times
- "No capability cliff" — the helpers loop is the differentiator
- "Auditable AI" — point at the helpers blocks, say "you can see the exact query"
- "Runs anywhere" — on-prem, air-gapped, your infrastructure

**Things NOT to say:**
- Don't say "zero configuration" — it's low-config
- Don't say "replaces SREs" — say "gives SREs superpowers"
- Don't say "60 seconds" — the investigation takes 3-4 minutes, and that's fine
- Don't oversell the model — "the intelligence is in the architecture, not the model"

**What if SABRE makes a mistake:**
If it queries a wrong table or gets a SQL error, let it self-correct. Say: "Watch — it hit an error, now it's adjusting. This is the iterative investigation in action." Self-correction is a feature, not a bug.

**What if someone asks about the model:**
"We're running gpt-4o-mini here — one of the cheapest available. SABRE also works with open-source models like Gemma, Llama, Mistral. The investigation quality comes from the architecture, not the model. A smaller model with the right tooling outperforms a frontier model without it."

**What if someone asks about ClickHouse specifically:**
"SABRE's ClickHouse integration includes the full OpenTelemetry schema — table names, column types, Map field access patterns, time windowing. The model doesn't need to discover the schema. ClickHouse's own research showed that frontier models fail at RCA against observability data because they lack this domain knowledge. We built it in."

## Demo Prompts (copy-paste ready)

```
use clickhouse integration
```

```
We had performance issues around 19:15 to 19:40 UTC yesterday. Investigate which services had the highest latency and error rates.
```

```
Drill down into accounting service. Look for errors including exception stack traces.
```

```
Look at the source code in github repo open-telemetry/opentelemetry-demo at src/accounting. What is causing the duplicate key constraint violation?
```

```
Look at the Kafka consumer configuration in Consumer.cs. Why would the same orderId be consumed twice? What is the fix?
```

## Teardown

```bash
cd sabre-ch-demo
./teardown.sh
```
