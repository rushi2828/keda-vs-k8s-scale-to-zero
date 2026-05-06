#!/usr/bin/env bash
# ============================================================
# Setup Script: Bootstrap the full KEDA vs Native HPA demo
# Run this after: terraform apply
# ============================================================

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-keda-vs-hpa-demo}"
AWS_REGION="${AWS_REGION:-us-east-1}"
KEDA_VERSION="2.16.0"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${BLUE}[SETUP]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }

log "Setting up KEDA vs Native HPA demo..."
echo ""

# 1. Configure kubectl
log "1/6 Configuring kubectl..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
ok "kubectl configured"

# 2. Verify cluster version
K8S_VERSION=$(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}')
log "2/6 Kubernetes version: $K8S_VERSION"
MINOR=$(echo "$K8S_VERSION" | tr -d 'v' | cut -d. -f2)
if [ "$MINOR" -ge 36 ]; then
  ok "K8s 1.36+ detected — HPAScaleToZero enabled by default"
else
  warn "K8s < 1.36 — native HPA scale-to-zero requires feature gate. Consider upgrading."
fi

# 3. Install KEDA
log "3/6 Installing KEDA $KEDA_VERSION..."
helm repo add kedacore https://kedacore.github.io/charts --force-update
helm repo update kedacore
helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --version "$KEDA_VERSION" \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$(
    terraform -chdir=terraform/environments/dev output -raw keda_irsa_arn 2>/dev/null || echo 'REPLACE_WITH_IRSA_ARN'
  )" \
  --wait
ok "KEDA installed"

# 4. Install Prometheus + Grafana (for monitoring)
log "4/6 Installing monitoring stack (Prometheus + Grafana)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update prometheus-community
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=admin123 \
  --set grafana.service.type=LoadBalancer \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout 5m
ok "Monitoring stack installed"

# 5. Deploy KEDA demo
log "5/6 Deploying KEDA demo (SQS worker)..."
SQS_QUEUE_URL=$(terraform -chdir=terraform/environments/dev output -raw sqs_queue_url 2>/dev/null || echo '')
if [ -n "$SQS_QUEUE_URL" ]; then
  # Patch queue URL into manifests
  sed -i.bak "s|https://sqs.us-east-1.amazonaws.com/ACCOUNT_ID/keda-vs-hpa-demo-keda-demo|${SQS_QUEUE_URL}|g" \
    k8s/keda/01-deployment.yaml k8s/keda/02-scaled-object.yaml
  ok "Queue URL patched into manifests"
else
  warn "Could not get SQS URL from Terraform. Update k8s/keda/*.yaml manually."
fi
kubectl apply -f k8s/keda/
ok "KEDA demo deployed"

# 6. Deploy Native HPA demo
log "6/6 Deploying Native HPA demo..."
kubectl apply -f k8s/native-hpa/
ok "Native HPA demo deployed"

echo ""
echo "══════════════════════════════════════════"
echo "  ✅  Setup complete!"
echo "══════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. Watch KEDA scale to zero:"
echo "     watch kubectl get pods -n keda-demo"
echo ""
echo "  2. Send load and watch scale-up:"
echo "     ./scripts/load-generator.sh 50"
echo ""
echo "  3. Run full benchmark:"
echo "     ./scripts/benchmark.sh"
echo ""
echo "  4. Access Grafana dashboard:"
GRAFANA_URL=$(kubectl get svc kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending...")
echo "     http://${GRAFANA_URL} (admin / admin123)"
echo ""
