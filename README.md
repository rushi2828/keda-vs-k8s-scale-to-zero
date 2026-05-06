# KEDA vs Kubernetes Native HPA: Scale-to-Zero Showdown 🚀

> A comprehensive demo comparing **KEDA (Kubernetes Event-Driven Autoscaler)** vs **Kubernetes 1.36 native HPA scale-to-zero** (HPAScaleToZero feature gate) on AWS EKS using Terraform.

[![Terraform](https://img.shields.io/badge/terraform-%235835CC.svg?style=for-the-badge&logo=terraform&logoColor=white)](https://terraform.io)
[![AWS](https://img.shields.io/badge/AWS-%23FF9900.svg?style=for-the-badge&logo=amazon-aws&logoColor=white)](https://aws.amazon.com)
[![Kubernetes](https://img.shields.io/badge/kubernetes-%23326ce5.svg?style=for-the-badge&logo=kubernetes&logoColor=white)](https://kubernetes.io)
[![KEDA](https://img.shields.io/badge/KEDA-scale%20to%20zero-blue?style=for-the-badge)](https://keda.sh)

---

## 🧠 What This Project Demonstrates

| Feature | KEDA | Native HPA (K8s 1.36+) |
|---|---|---|
| Scale to Zero | ✅ Mature, Production-ready | ✅ Alpha→Beta→Enabled by default in 1.36 |
| Event Sources | 70+ (SQS, RabbitMQ, Redis, etc.) | CPU/Memory + External Metrics (alpha) |
| External Metrics | ✅ Native | ⚠️ Limited (KEP-2015, alpha in 1.36) |
| Cold Start Handling | Via HTTP Add-on | Pod readiness gates |
| Complexity | Medium (CRDs + ScaledObject) | Low (native HPA + feature gate) |
| Best For | Event-driven / Queue workers | HTTP-based workloads with simple metrics |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────┐
│                        AWS                              │
│  ┌─────────┐    ┌──────────────────────────────────┐   │
│  │   SQS   │───▶│           EKS Cluster            │   │
│  │  Queue  │    │                                  │   │
│  └─────────┘    │  ┌─────────────┐  ┌───────────┐ │   │
│                 │  │ KEDA Demo   │  │Native HPA │ │   │
│  ┌─────────┐    │  │  Namespace  │  │  Demo NS  │ │   │
│  │CloudWatch│   │  │             │  │           │ │   │
│  │ Metrics  │───▶│  │ScaledObject │  │   HPA v2  │ │   │
│  └─────────┘    │  │SQS Scaler   │  │minReplicas│ │   │
│                 │  │0→N pods     │  │   =0      │ │   │
│  ┌─────────┐    │  └─────────────┘  └───────────┘ │   │
│  │Karpenter│◀───│                                  │   │
│  │  Nodes  │    │  ┌────────────────────────────┐  │   │
│  └─────────┘    │  │   Monitoring (Prometheus   │  │   │
│                 │  │       + Grafana)            │  │   │
│                 │  └────────────────────────────┘  │   │
│                 └──────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

---

## 📁 Project Structure

```
keda-vs-k8s-scale-to-zero/
├── README.md
├── terraform/
│   ├── modules/
│   │   ├── eks/          # EKS cluster + Karpenter node pools
│   │   ├── sqs/          # SQS queues for KEDA demo
│   │   └── iam/          # IRSA roles for KEDA + pod identity
│   └── environments/
│       └── dev/          # Dev environment root module
├── k8s/
│   ├── keda/             # KEDA install + ScaledObject manifests
│   ├── native-hpa/       # Native HPA with HPAScaleToZero
│   └── apps/             # Sample worker app manifests
├── scripts/
│   ├── load-generator.sh # SQS message generator for testing
│   ├── benchmark.sh      # Capture scale-up latency metrics
│   └── setup.sh          # Bootstrap script
├── monitoring/
│   ├── prometheus/       # ServiceMonitor configs
│   └── grafana/          # Dashboard JSON
├── demo/
│   └── walkthrough.sh    # Interactive demo script
└── docs/
    ├── COMPARISON.md     # Detailed comparison notes
    └── MEDIUM_ARTICLE.md # Full Medium article draft
```

---

## 🚀 Quick Start

### Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.7
- kubectl >= 1.28
- Helm >= 3.14
- `jq`, `curl`, `watch`

### 1. Provision Infrastructure

```bash
cd terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your AWS account details

terraform init
terraform plan
terraform apply
```

### 2. Configure kubectl

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name keda-vs-hpa-demo
```

### 3. Install KEDA

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --version 2.16.0
```

### 4. Deploy Demo Apps

```bash
# Deploy KEDA SQS worker
kubectl apply -f k8s/keda/

# Deploy Native HPA worker (requires K8s 1.36+)
kubectl apply -f k8s/native-hpa/

# Deploy sample worker app
kubectl apply -f k8s/apps/
```

### 5. Run the Benchmark

```bash
chmod +x scripts/*.sh
./scripts/benchmark.sh
```

---

## 🔬 Key Findings

### KEDA: Proven, Feature-Rich Scale-to-Zero
- **0→1 latency**: ~15-30s (pod scheduling + container pull)
- **Trigger**: SQS queue depth, Prometheus metrics, 70+ sources
- **Cold start problem**: Solved via KEDA HTTP Add-on (proxy queues requests)
- **Production-ready**: CNCF Graduated project

### Native HPA (K8s 1.36 HPAScaleToZero):
- **Feature gate**: `HPAScaleToZero=true` (enabled by default in 1.36)
- **0→1 latency**: ~20-45s (no pre-warming)
- **Trigger**: External metrics only (not CPU when at 0 pods)
- **Limitation**: Needs external metric source when at zero (no pods = no CPU metrics)
- **Sweet spot**: Simple workloads in managed K8s environments

### The Verdict
> Use **KEDA** for event-driven workloads (queues, streaming, batch).
> Use **Native HPA scale-to-zero** for simple HTTP workloads on K8s 1.36+ where operational simplicity matters.

---

## 📖 Read the Full Article

See "MEDIUM_ARTICLE_LINK" for the complete Medium article.

---

## 🧹 Cleanup

```bash
cd terraform/environments/dev
terraform destroy
```

---

## 📄 License

MIT — See [LICENSE](LICENSE)
