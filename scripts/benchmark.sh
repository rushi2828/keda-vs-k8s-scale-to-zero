#!/usr/bin/env bash
# ============================================================
# Benchmark: Compare KEDA vs Native HPA Scale-to-Zero Latency
# Measures time from trigger → first ready pod
# ============================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
QUEUE_URL="${QUEUE_URL:-}"
RESULTS_FILE="benchmark-results-$(date +%Y%m%d-%H%M%S).json"
RUNS="${RUNS:-3}"  # Number of benchmark runs per scenario

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}\n"; }
log()    { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()     { echo -e "${GREEN}✓${NC} $*"; }
warn()   { echo -e "${YELLOW}⚠${NC} $*"; }

# Get queue URL from kubectl if not set
if [ -z "$QUEUE_URL" ]; then
  QUEUE_URL=$(kubectl get configmap keda-demo-config -n keda-demo \
    -o jsonpath='{.data.sqs_queue_url}' 2>/dev/null || true)
fi

if [ -z "$QUEUE_URL" ]; then
  echo "Error: QUEUE_URL environment variable not set"
  echo "Set it via: export QUEUE_URL=\$(terraform output -raw sqs_queue_url)"
  exit 1
fi

# ────────────────────────────────────────────────────────────
# Helper: Force a deployment to zero and measure scale-up time
# ────────────────────────────────────────────────────────────
measure_scale_up_latency() {
  local namespace="$1"
  local deployment="$2"
  local trigger_fn="$3"  # function name to call to trigger scaling
  local description="$4"

  log "Forcing $deployment to 0 replicas..."

  # Scale to 0 manually (bypass autoscaler)
  kubectl scale deployment "$deployment" -n "$namespace" --replicas=0
  kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout=30s || true

  # Wait for all pods to terminate
  sleep 5
  BEFORE=$(kubectl get deployment "$deployment" -n "$namespace" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  log "Replicas before trigger: ${BEFORE:-0}"

  # Record trigger time and run the trigger function
  TRIGGER_TIME=$(date +%s%3N)  # milliseconds
  log "Triggering $description at $(date '+%H:%M:%S.%3N')..."
  $trigger_fn

  # Poll for first ready pod
  local TIMEOUT=180
  local START=$(date +%s)
  local FIRST_POD_TIME=0

  while true; do
    READY=$(kubectl get deployment "$deployment" -n "$namespace" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    NOW=$(date +%s)

    if [ "${READY:-0}" -ge 1 ] && [ "$FIRST_POD_TIME" -eq 0 ]; then
      FIRST_POD_TIME=$(date +%s%3N)
      LATENCY_MS=$((FIRST_POD_TIME - TRIGGER_TIME))
      ok "First pod ready! Latency: ${LATENCY_MS}ms ($(( LATENCY_MS / 1000 ))s)"
      echo "$LATENCY_MS"
      return 0
    fi

    if [ $((NOW - START)) -ge "$TIMEOUT" ]; then
      warn "Timeout waiting for scale-up after ${TIMEOUT}s"
      echo "-1"
      return 1
    fi

    sleep 2
  done
}

# Trigger function for KEDA (sends SQS messages)
trigger_keda() {
  local COUNT=20
  ENTRIES=""
  for i in $(seq 1 "$COUNT"); do
    ENTRIES="${ENTRIES}{\"Id\":\"bench${i}\",\"MessageBody\":\"{\\\"job\\\":\\\"benchmark-${i}\\\"}\"},"
  done
  ENTRIES="[${ENTRIES%,}]"

  aws sqs send-message-batch \
    --queue-url "$QUEUE_URL" \
    --entries "$ENTRIES" \
    --region "$AWS_REGION" \
    --output text > /dev/null
}

# Trigger function for Native HPA (sends HTTP traffic, simulated via annotation)
trigger_native_hpa() {
  # For the native HPA demo, we trigger by updating the SQS external metric
  # In real scenario this would be HTTP load or SQS messages
  trigger_keda  # Same SQS queue for comparison
}

# ────────────────────────────────────────────────────────────
# Run Benchmarks
# ────────────────────────────────────────────────────────────
header "KEDA vs Native HPA Scale-to-Zero Benchmark"
log "Runs per scenario: $RUNS"
log "Results will be saved to: $RESULTS_FILE"

KEDA_LATENCIES=()
HPA_LATENCIES=()

# Benchmark KEDA
header "Scenario 1: KEDA SQS Scale-to-Zero"
for run in $(seq 1 "$RUNS"); do
  log "Run $run/$RUNS..."
  LATENCY=$(measure_scale_up_latency \
    "keda-demo" \
    "sqs-worker" \
    "trigger_keda" \
    "SQS message burst")
  KEDA_LATENCIES+=("$LATENCY")
  log "Run $run KEDA latency: ${LATENCY}ms"
  sleep 30  # Cooldown between runs
done

# Benchmark Native HPA (if cluster is 1.36+)
K8S_VERSION=$(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}' | sed 's/v//')
MAJOR=$(echo "$K8S_VERSION" | cut -d. -f1)
MINOR=$(echo "$K8S_VERSION" | cut -d. -f2)

header "Scenario 2: Native HPA (minReplicas=0) Scale-to-Zero"
if [ "$MINOR" -ge 36 ] || [ "$MAJOR" -gt 1 ]; then
  log "K8s $K8S_VERSION detected — HPAScaleToZero enabled by default ✓"
  for run in $(seq 1 "$RUNS"); do
    log "Run $run/$RUNS..."
    LATENCY=$(measure_scale_up_latency \
      "native-hpa-demo" \
      "http-worker" \
      "trigger_native_hpa" \
      "SQS external metric threshold")
    HPA_LATENCIES+=("$LATENCY")
    log "Run $run Native HPA latency: ${LATENCY}ms"
    sleep 30
  done
else
  warn "K8s $K8S_VERSION — HPAScaleToZero requires 1.36+. Skipping native HPA benchmark."
  warn "Update cluster_version = \"1.36\" in your Terraform config."
fi

# ────────────────────────────────────────────────────────────
# Results Summary
# ────────────────────────────────────────────────────────────
header "📊 Benchmark Results"

avg_latency() {
  local arr=("$@")
  local sum=0
  local count=0
  for val in "${arr[@]}"; do
    if [ "$val" -gt 0 ]; then
      sum=$((sum + val))
      count=$((count + 1))
    fi
  done
  if [ "$count" -gt 0 ]; then
    echo $((sum / count))
  else
    echo "N/A"
  fi
}

KEDA_AVG=$(avg_latency "${KEDA_LATENCIES[@]}")
HPA_AVG=$(avg_latency "${HPA_LATENCIES[@]}" 2>/dev/null || echo "N/A")

echo ""
echo "┌──────────────────────────────────────────┐"
echo "│           Scale-to-Zero Latency           │"
echo "├──────────────────┬───────────────────────┤"
printf "│ %-16s │ %-21s │\n" "Approach" "Avg Latency (ms)"
echo "├──────────────────┼───────────────────────┤"
printf "│ %-16s │ %-21s │\n" "KEDA (SQS)" "${KEDA_AVG}ms"
printf "│ %-16s │ %-21s │\n" "Native HPA 1.36" "${HPA_AVG}ms"
echo "└──────────────────┴───────────────────────┘"
echo ""

# Save JSON results
cat > "$RESULTS_FILE" <<EOF
{
  "benchmark_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "kubernetes_version": "$K8S_VERSION",
  "runs_per_scenario": $RUNS,
  "keda": {
    "latencies_ms": [$(IFS=,; echo "${KEDA_LATENCIES[*]}")],
    "avg_latency_ms": $KEDA_AVG
  },
  "native_hpa": {
    "latencies_ms": [$(IFS=,; echo "${HPA_LATENCIES[*]:-}")],
    "avg_latency_ms": "${HPA_AVG}"
  }
}
EOF

ok "Results saved to $RESULTS_FILE"
log "Run 'cat $RESULTS_FILE | jq .' to view full results"
