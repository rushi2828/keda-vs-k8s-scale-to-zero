C:\Users\bbdnet10144\Music\keda-vs-k8s-scale-to-zero#!/usr/bin/env bash
# ============================================================
# Interactive Demo Walkthrough
# Live demonstration of KEDA vs Native HPA scale-to-zero
# Designed for conference talks, team demos, or blog recording
# ============================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"

# ── Colors & Formatting ────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ── Helpers ────────────────────────────────────────────────
pause() {
  echo ""
  echo -e "${DIM}Press ENTER to continue...${NC}"
  read -r
}

title() {
  clear
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
  printf "${BOLD}${CYAN}║${NC}  %-52s${BOLD}${CYAN}║${NC}\n" "$*"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
}

section() {
  echo ""
  echo -e "${BOLD}${MAGENTA}▶ $*${NC}"
  echo -e "${MAGENTA}$(printf '─%.0s' {1..56})${NC}"
}

cmd() {
  echo -e "\n${YELLOW}$ ${BOLD}$*${NC}"
  eval "$*"
}

info() { echo -e "${BLUE}ℹ${NC}  $*"; }
ok()   { echo -e "${GREEN}✓${NC}  $*"; }

# ── Get Queue URL ──────────────────────────────────────────
QUEUE_URL=$(kubectl get configmap keda-demo-config -n keda-demo \
  -o jsonpath='{.data.sqs_queue_url}' 2>/dev/null || echo "")

# ══════════════════════════════════════════════════════════
# SCENE 1: Introduction
# ══════════════════════════════════════════════════════════
title "KEDA vs Kubernetes 1.36 Native HPA"
echo -e "      ${BOLD}Scale-to-Zero: The Ultimate Showdown${NC}"
echo ""
echo -e "  Today we compare two approaches to scaling pods to zero:"
echo ""
echo -e "  ${GREEN}1. KEDA${NC} — Kubernetes Event-Driven Autoscaler"
echo -e "     CNCF Graduated, 70+ scalers, production-proven"
echo ""
echo -e "  ${BLUE}2. Native HPA${NC} — HPAScaleToZero (enabled by default in K8s 1.36)"
echo -e "     No extra operators, minReplicas: 0 just works"
echo ""
info "Both running on EKS 1.36 with SQS as the event source"
pause

# ══════════════════════════════════════════════════════════
# SCENE 2: Show current state — both at zero
# ══════════════════════════════════════════════════════════
title "Scene 1: Everything is Idle"

section "KEDA Demo Namespace"
cmd "kubectl get pods -n keda-demo"
echo ""
info "No pods running — KEDA scaled to zero because SQS queue is empty"

echo ""
section "Native HPA Demo Namespace"
cmd "kubectl get pods -n native-hpa-demo"
echo ""
info "No pods running — Native HPA (minReplicas=0) scaled to zero"

echo ""
section "HPA Status"
cmd "kubectl get hpa -n native-hpa-demo -o wide"
echo ""
info "Note the 'ScaledToZero' condition in K8s 1.36 HPA status"

pause

# ══════════════════════════════════════════════════════════
# SCENE 3: Show the KEDA config
# ══════════════════════════════════════════════════════════
title "Scene 2: How KEDA Achieves Scale-to-Zero"

section "The ScaledObject (KEDA's core resource)"
cmd "kubectl get scaledobject sqs-worker-scaler -n keda-demo -o yaml | grep -A 20 'spec:'"

echo ""
section "KEDA creates and manages an HPA automatically"
cmd "kubectl get hpa -n keda-demo"

echo ""
section "KEDA ScaledObject Status"
cmd "kubectl describe scaledobject sqs-worker-scaler -n keda-demo | grep -A 10 'Conditions:'"

pause

# ══════════════════════════════════════════════════════════
# SCENE 4: Show the Native HPA config
# ══════════════════════════════════════════════════════════
title "Scene 3: How Native HPA Achieves Scale-to-Zero (K8s 1.36)"

section "The HPA with minReplicas: 0"
cmd "kubectl get hpa http-worker-hpa -n native-hpa-demo -o yaml | grep -A 30 'spec:'"

echo ""
info "Key: minReplicas: 0 — this now works in K8s 1.36+ without any feature gate"
info "But: CPU metrics don't work at 0 pods. External metric (SQS via CloudWatch) needed"

pause

# ══════════════════════════════════════════════════════════
# SCENE 5: Live scale-up race — KEDA vs Native HPA
# ══════════════════════════════════════════════════════════
title "Scene 4: The Race — KEDA vs Native HPA Scale-Up"

section "Starting the race..."
info "We'll send 20 SQS messages and measure which approach scales up first"
echo ""

# Force both to zero
echo -e "${YELLOW}Forcing both deployments to 0...${NC}"
kubectl scale deployment sqs-worker -n keda-demo --replicas=0 2>/dev/null || true
kubectl scale deployment http-worker -n native-hpa-demo --replicas=0 2>/dev/null || true
sleep 10

KEDA_READY=false
HPA_READY=false
KEDA_TIME=0
HPA_TIME=0

RACE_START=$(date +%s)

# Send messages to trigger both
if [ -n "$QUEUE_URL" ]; then
  echo -e "${YELLOW}Sending 20 SQS messages...${NC}"
  ENTRIES=""
  for i in $(seq 1 10); do
    ENTRIES="${ENTRIES}{\"Id\":\"r${i}\",\"MessageBody\":\"{\\\"race\\\":\\\"${i}\\\"}\"},"
  done
  ENTRIES="[${ENTRIES%,}]"
  aws sqs send-message-batch \
    --queue-url "$QUEUE_URL" \
    --entries "$ENTRIES" \
    --region "$AWS_REGION" \
    --output text > /dev/null
  ok "Messages sent at $(date '+%H:%M:%S')"
fi

echo ""
echo -e "${BOLD}Watching for scale-up (updates every 3s)...${NC}"
echo ""

for i in $(seq 1 40); do
  NOW=$(date +%s)
  ELAPSED=$((NOW - RACE_START))

  KEDA_PODS=$(kubectl get deployment sqs-worker -n keda-demo \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  HPA_PODS=$(kubectl get deployment http-worker -n native-hpa-demo \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

  if [ "${KEDA_PODS:-0}" -ge 1 ] && [ "$KEDA_READY" = "false" ]; then
    KEDA_READY=true
    KEDA_TIME=$ELAPSED
  fi

  if [ "${HPA_PODS:-0}" -ge 1 ] && [ "$HPA_READY" = "false" ]; then
    HPA_READY=true
    HPA_TIME=$ELAPSED
  fi

  KEDA_STATUS="${KEDA_PODS:-0} pods"
  HPA_STATUS="${HPA_PODS:-0} pods"
  [ "$KEDA_READY" = "true" ] && KEDA_STATUS="${GREEN}${KEDA_PODS} pods ✓ (${KEDA_TIME}s)${NC}"
  [ "$HPA_READY" = "true" ] && HPA_STATUS="${GREEN}${HPA_PODS} pods ✓ (${HPA_TIME}s)${NC}"

  printf "\r  ⏱  %3ds  │  KEDA: %-40b│  Native HPA: %b" \
    "$ELAPSED" "$KEDA_STATUS" "$HPA_STATUS"

  if [ "$KEDA_READY" = "true" ] && [ "$HPA_READY" = "true" ]; then
    break
  fi

  sleep 3
done

echo ""
echo ""
section "Race Results"
echo ""
printf "  %-20s %s\n" "KEDA scale-up:" "${KEDA_TIME}s"
printf "  %-20s %s\n" "Native HPA scale-up:" "${HPA_TIME}s"
echo ""

if [ "$KEDA_TIME" -lt "$HPA_TIME" ] && [ "$KEDA_TIME" -gt 0 ]; then
  ok "KEDA won by $((HPA_TIME - KEDA_TIME)) seconds"
  info "KEDA's advantage: 10s polling interval vs CloudWatch's 30s minimum"
elif [ "$HPA_TIME" -lt "$KEDA_TIME" ] && [ "$HPA_TIME" -gt 0 ]; then
  ok "Native HPA won by $((KEDA_TIME - HPA_TIME)) seconds"
else
  info "Results vary by run — both are close in latency"
fi

pause

# ══════════════════════════════════════════════════════════
# SCENE 6: Summary
# ══════════════════════════════════════════════════════════
title "Scene 5: Summary & Decision Guide"

echo -e "  ${BOLD}Use KEDA when:${NC}"
echo "  • Event-driven workloads (SQS, RabbitMQ, Redis)"
echo "  • Multi-trigger scaling logic"
echo "  • HTTP cold-start protection (KEDA HTTP Add-on)"
echo "  • You need production-proven scale-to-zero today"
echo ""
echo -e "  ${BOLD}Use Native HPA (K8s 1.36+) when:${NC}"
echo "  • Simple HTTP workloads"
echo "  • Minimizing cluster components"
echo "  • Dev/staging cost optimization"
echo "  • You're already on managed K8s 1.36+"
echo ""
echo -e "  ${BOLD}They're not mutually exclusive — many clusters run both.${NC}"
echo ""
info "Full code: github.com/YOUR_USERNAME/keda-vs-k8s-scale-to-zero"
info "Full article: medium.com — see docs/MEDIUM_ARTICLE.md"
echo ""
echo -e "${GREEN}${BOLD}Demo complete! 🎉${NC}"
echo ""
