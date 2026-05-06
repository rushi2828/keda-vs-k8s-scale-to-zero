# KEDA vs Native HPA Scale-to-Zero: Detailed Comparison

## Feature Matrix

| Feature | KEDA 2.16 | Native HPA (K8s 1.36) |
|---|---|---|
| Scale to 0 | ✅ Stable | ✅ Enabled by default in 1.36 |
| Scale from 0 | ✅ Event-driven | ⚠️ Requires external metric adapter |
| CPU triggers | ✅ (via Prometheus) | ✅ Native |
| Memory triggers | ✅ (via Prometheus) | ✅ Native |
| SQS triggers | ✅ Native scaler | ⚠️ Via k8s-cloudwatch-adapter |
| RabbitMQ triggers | ✅ Native scaler | ❌ No native support |
| HTTP triggers | ✅ Via HTTP Add-on | ⚠️ Via custom metrics |
| Cron scaling | ✅ Cron scaler | ❌ Not supported |
| Multi-trigger | ✅ AND/OR logic | ⚠️ Multiple metrics, OR-only |
| Cold start (HTTP) | ✅ HTTP Add-on queues requests | ❌ Requests dropped during cold start |
| Polling interval | 1–30s (configurable) | 15s (metrics-server), 30s+ (CW) |
| CRDs required | Yes (ScaledObject, etc.) | No |
| Extra operators | keda-operator + metrics-server | External metrics adapter only |
| RBAC complexity | Medium | Low |
| Helm chart | ✅ Official | ❌ N/A |
| CNCF status | Graduated | N/A (core Kubernetes) |

## Architecture Diagrams

### KEDA Architecture
```
External Source (SQS)
        │
        │ poll every N seconds
        ▼
  KEDA Operator
        │
        │ expose via External Metrics API
        ▼
  Kubernetes HPA ──────────────────▶ Deployment (0-N pods)
        │
        │ if no events
        ▼
  replicas: 0 (KEDA bypasses HPA minimum)
```

### Native HPA Scale-to-Zero Architecture
```
CloudWatch (SQS metrics)
        │
        │ poll every 30s
        ▼
k8s-cloudwatch-adapter
        │
        │ expose via External Metrics API
        ▼
  Kubernetes HPA ──────────────────▶ Deployment (0-N pods)
        │
        │ if metric < threshold
        ▼
  minReplicas: 0 (K8s 1.36+ feature gate)
```

## Cold Start Timing Breakdown

```
Time →  0s    5s    10s   15s   20s   25s   30s   35s
        │     │     │     │     │     │     │     │
KEDA    │POLL │     │SCALE│POD  │POD  │READY│     │
        │ SQS │     │DECIS│SCHED│PULL │     │     │
        │     │     │ION  │     │     │     │     │
        │     │     │     │     │     │     │     │
Native  │     │     │     │CW   │     │SCALE│POD  │POD  ...READY
HPA     │     │     │     │POLL │     │DEC  │SCHED│PULL
```

## When Scale-to-Zero Is NOT Right

1. **Low-latency user-facing APIs** — Cold starts will impact p99 latency
2. **WebSocket services** — Connection state is lost on scale-down
3. **Stateful workloads** — Rehydrating state on scale-up adds latency
4. **High-frequency batch jobs** — Constant scaling thrash negates savings

## Recommended Configurations

### KEDA Production Config

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
spec:
  minReplicaCount: 0
  maxReplicaCount: 50
  pollingInterval: 15        # Balance between responsiveness and API calls
  cooldownPeriod: 300        # 5 min — let queue drain fully before scaling down
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 180  # Avoid flapping
        scaleUp:
          stabilizationWindowSeconds: 0    # React immediately
```

### Native HPA Production Config

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  minReplicas: 0
  maxReplicas: 50
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      selectPolicy: Max
```
