#!/usr/bin/env bash
# ============================================================
# Load Generator: Send messages to SQS to trigger KEDA scaling
# Usage: ./load-generator.sh [num_messages] [queue_url]
# ============================================================

set -euo pipefail

NUM_MESSAGES="${1:-50}"
QUEUE_URL="${2:-$(kubectl get configmap keda-demo-config -n keda-demo -o jsonpath='{.data.sqs_queue_url}' 2>/dev/null || echo '')}"
BATCH_SIZE=10  # SQS max batch size
AWS_REGION="${AWS_REGION:-us-east-1}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*" >&2; }

if [ -z "$QUEUE_URL" ]; then
  error "QUEUE_URL is required. Pass as argument or ensure keda-demo-config ConfigMap exists."
  echo "Usage: $0 [num_messages] [queue_url]"
  exit 1
fi

log "🚀 Starting load generator"
log "Queue: $QUEUE_URL"
log "Messages to send: $NUM_MESSAGES"
echo ""

# Record the current replica count before sending messages
BEFORE_REPLICAS=$(kubectl get deployment sqs-worker -n keda-demo -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
log "Current replicas before load: ${BEFORE_REPLICAS:-0}"
log "Sending $NUM_MESSAGES messages in batches of $BATCH_SIZE..."
echo ""

START_TIME=$(date +%s)
MESSAGES_SENT=0

while [ "$MESSAGES_SENT" -lt "$NUM_MESSAGES" ]; do
  # Build batch of messages (up to BATCH_SIZE)
  REMAINING=$((NUM_MESSAGES - MESSAGES_SENT))
  BATCH=$(( REMAINING > BATCH_SIZE ? BATCH_SIZE : REMAINING ))

  # Create SQS batch entries
  ENTRIES=""
  for i in $(seq 1 "$BATCH"); do
    ID=$((MESSAGES_SENT + i))
    ENTRIES="${ENTRIES}{\"Id\":\"msg${ID}\",\"MessageBody\":\"{\\\"job_id\\\":\\\"job-${ID}\\\",\\\"timestamp\\\":\\\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\\\",\\\"payload\\\":\\\"simulate-work-${RANDOM}\\\"}\"},"
  done
  # Remove trailing comma
  ENTRIES="[${ENTRIES%,}]"

  aws sqs send-message-batch \
    --queue-url "$QUEUE_URL" \
    --entries "$ENTRIES" \
    --region "$AWS_REGION" \
    --output text > /dev/null

  MESSAGES_SENT=$((MESSAGES_SENT + BATCH))
  echo -ne "\r  Sent: ${MESSAGES_SENT}/${NUM_MESSAGES} messages"
done

echo ""
SEND_END=$(date +%s)
success "All $NUM_MESSAGES messages sent in $((SEND_END - START_TIME))s"
echo ""

# Watch scaling happen
log "📊 Watching for KEDA to scale up the deployment..."
log "   (Press Ctrl+C to stop watching)"
echo ""

SCALE_DETECTED=false
CHECK_INTERVAL=5
TIMEOUT=120
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  REPLICAS=$(kubectl get deployment sqs-worker -n keda-demo -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  QUEUE_DEPTH=$(aws sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "?")

  printf "\r  ⏱  %3ds | Replicas: %s | Queue depth: %s     " \
    "$ELAPSED" "${REPLICAS:-0}" "$QUEUE_DEPTH"

  if [ "${REPLICAS:-0}" -gt "0" ] && [ "$SCALE_DETECTED" = "false" ]; then
    SCALE_DETECTED=true
    SCALE_TIME=$(date +%s)
    LATENCY=$((SCALE_TIME - SEND_END))
    echo ""
    echo ""
    success "🎉 KEDA scaled from 0 → ${REPLICAS} replica(s) in ${LATENCY}s!"
    echo ""
    log "Benchmark result:"
    echo "  Message send time:   $((SEND_END - START_TIME))s"
    echo "  Scale-up latency:    ${LATENCY}s (from first message to first ready pod)"
    echo "  Final replicas:      $REPLICAS"
    echo ""
  fi

  sleep "$CHECK_INTERVAL"
  ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done

echo ""
if [ "$SCALE_DETECTED" = "false" ]; then
  warn "Scale-up not detected within ${TIMEOUT}s. Check KEDA logs:"
  echo "  kubectl logs -n keda -l app=keda-operator --tail=50"
fi

log "Done! Run benchmark.sh to compare KEDA vs native HPA latencies."
