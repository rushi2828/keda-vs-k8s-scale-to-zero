#!/usr/bin/env bash
# ============================================================
# cleanup-queue.sh
# Purges all messages from SQS queues.
# Useful between benchmark runs to reset to a clean state.
# Usage: ./scripts/cleanup-queue.sh
# ============================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

# Get queue URLs from kubectl ConfigMap or Terraform
QUEUE_URL="${QUEUE_URL:-$(kubectl get configmap worker-config -n keda-demo \
  -o jsonpath='{.data.QUEUE_URL}' 2>/dev/null || echo "")}"

if [ -z "$QUEUE_URL" ]; then
  QUEUE_URL=$(cd terraform/environments/dev 2>/dev/null && \
    terraform output -raw sqs_queue_url 2>/dev/null || echo "")
fi

if [ -z "$QUEUE_URL" ]; then
  echo "Error: Could not find QUEUE_URL. Set it manually:"
  echo "  export QUEUE_URL=\$(terraform -chdir=terraform/environments/dev output -raw sqs_queue_url)"
  exit 1
fi

log "Queue URL: $QUEUE_URL"

# Check current queue depth
DEPTH=$(aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --region "$AWS_REGION" \
  --query 'Attributes' \
  --output json)

VISIBLE=$(echo "$DEPTH" | jq -r '.ApproximateNumberOfMessages // "0"')
IN_FLIGHT=$(echo "$DEPTH" | jq -r '.ApproximateNumberOfMessagesNotVisible // "0"')

log "Current queue state:"
echo "  Visible messages:   $VISIBLE"
echo "  In-flight messages: $IN_FLIGHT"
echo ""

if [ "$VISIBLE" = "0" ] && [ "$IN_FLIGHT" = "0" ]; then
  ok "Queue is already empty — nothing to clean up"
  exit 0
fi

warn "This will permanently delete all $VISIBLE visible messages"
echo -n "Continue? (y/N): "
read -r confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
  echo "Cancelled."
  exit 0
fi

log "Purging queue..."
aws sqs purge-queue \
  --queue-url "$QUEUE_URL" \
  --region "$AWS_REGION"

ok "Queue purged. Note: SQS purge takes up to 60 seconds to propagate."

# Also scale both deployments to 0 for a clean benchmark reset
log "Scaling both demo deployments to 0..."
kubectl scale deployment sqs-worker -n keda-demo --replicas=0 2>/dev/null || true
kubectl scale deployment http-worker -n native-hpa-demo --replicas=0 2>/dev/null || true
ok "Deployments scaled to 0"

log "Waiting 65 seconds for SQS purge to propagate..."
sleep 65

# Verify
FINAL=$(aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --region "$AWS_REGION" \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text)

ok "Queue depth now: $FINAL"
ok "Ready for next benchmark run"
