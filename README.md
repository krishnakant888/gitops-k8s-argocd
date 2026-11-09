# gitops-k8s-argocd

Local Kubernetes platform (kind/minikube) managed entirely from Git via Argo CD. Push a manifest, Argo CD syncs it. No `kubectl apply` after bootstrap.

---

## Table of contents

1. [Architecture](#architecture)
2. [Stack](#stack)
3. [Bootstrap](#bootstrap)
4. [Day-two operations](#day-two-operations)
5. [SRE agent integration](#sre-agent-integration)
6. [Alert rules](#alert-rules)
7. [Fault injection scenarios](#fault-injection-scenarios)
8. [Moving to AKS](#moving-to-aks)
9. [Moving to EKS](#moving-to-eks)
10. [WSL / kind tips](#wsl--kind-tips)

---

## Architecture

```
GitHub (this repo)
      │  push
      ▼
  Argo CD  ──────────────────────────────────────────────────────────────
  (kind-gitops)                                                          │
      │  root-app watches k8s/apps/                                      │
      │  deploys each Application to kubernetes.default.svc             │
      ▼                                                                  │
  kind-platform  (workload cluster)                                      │
  ┌──────────────────────────────────────────────────────────────────┐  │
  │  namespace: monitoring                                           │  │
  │    Loki (single-binary, filesystem)                              │  │
  │    Grafana (alert rules + dashboards + contact points)           │  │
  │                                                                  │  │
  │  namespace: observability                                        │  │
  │    Alloy  ──► Mimir (metrics)  Loki (logs)  Tempo (traces)      │  │
  │    kube-state-metrics                                            │  │
  │                                                                  │  │
  │  namespace: sre-agent                                            │  │
  │    alert-webhook  (receives Grafana alerts → starts workflows)   │  │
  │    rca-viewer     (UI for investigation reports)                 │  │
  │                                                                  │  │
  │  namespace: demo                                                 │  │
  │    orders-api  (sample workload, Gateway API ingress)            │  │
  │                                                                  │  │
  │  namespace: sandbox                                              │  │
  │    dummy-shop  (sample workload)                                 │  │
  └──────────────────────────────────────────────────────────────────┘  │
                                                                         │
  Argo CD also manages k8s-sre-platform (platform cluster) ─────────────┘
```

**GitOps rule:** every resource is declared in `k8s/apps/` or `k8s/workloads/`. Argo CD has `prune: true` and `selfHeal: true` on every app — anything deleted from Git is deleted from the cluster.

---

## Stack

| App | Chart / source | Namespace | Purpose |
|-----|---------------|-----------|---------|
| `loki` | `grafana/loki 6.16.0` | `monitoring` | Log storage (single-binary, filesystem) |
| `grafana` | `grafana/grafana 8.5.2` | `monitoring` | Dashboards, alert rules, contact points |
| `alloy-config` | `k8s-sre-platform` repo | `observability` | ConfigMap: Alloy pipeline (metrics + logs + traces) |
| `alloy` | `grafana/alloy 1.14.2` | `observability` | Collector — cAdvisor, kubelet, kube-state-metrics, pods → Mimir; logs → Loki; traces → Tempo |
| `sre-agent` | `k8s/workloads/sre-agent/` | `sre-agent` | Webhook stub (replace with real agent) |
| `frontend` | `k8s/workloads/frontend/` | `frontend` | Demo nginx workload |

**Observability pipeline:**

```
cAdvisor / kubelet / kube-state-metrics / annotated pods
    └─► Alloy ─► prometheus.remote_write ─► Mimir
                                                └─► Grafana (metrics)

every pod stdout/stderr
    └─► Alloy loki.source.kubernetes ─► Loki
                                           └─► Grafana (logs + alert rules)

OTLP (apps)
    └─► Alloy otelcol.receiver.otlp ─► Tempo
                                           └─► Grafana (traces)
```

Alloy scrapes anything with a container port named `metrics` or the annotation `prometheus.io/scrape: "true"` — no per-workload config needed.

---

## Bootstrap

**Prerequisites:** Docker, `minikube` (or `kind`), `kubectl`, `git`.

```bash
git clone https://github.com/krishnakant888/gitops-k8s-argocd.git
cd gitops-k8s-argocd
bash scripts/bootstrap.sh
```

The script:
1. Starts a minikube cluster (`profile: gitops`, 4 CPU, 6 GB)
2. Installs Argo CD into `argocd`
3. Applies `k8s/root-app.yaml` — the app-of-apps that watches `k8s/apps/`
4. Prints the Argo CD admin password

**Access:**
```bash
# Argo CD UI
kubectl -n argocd port-forward svc/argocd-server 8080:443
# https://localhost:8080  user: admin

# Grafana
kubectl -n monitoring port-forward svc/grafana 3000:80
# http://localhost:3000  user: admin  pass: (from secret)
kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

---

## Day-two operations

**Add a workload:**
1. Create a manifest under `k8s/workloads/<name>/`
2. Add a `k8s/apps/<name>.yaml` Argo CD Application pointing to it
3. Push — Argo CD syncs within 3 minutes (or click **Sync** in the UI)

**Remove a workload:**
Delete the `k8s/apps/<name>.yaml` file and push. `prune: true` ensures Argo CD deletes the Application and its resources from the cluster.

**Update a Helm chart version:**
Change `targetRevision` in the relevant `k8s/apps/*.yaml` and push.

**Force immediate sync:**
```bash
kubectl -n argocd patch app <name> --type merge -p '{"operation":{"initiatedBy":{"username":"cli"},"sync":{}}}'
# or simply: argocd app sync <name>
```

---

## SRE agent integration

`k8s/workloads/sre-agent/stub.yaml` is a stub deployment that logs incoming webhook bodies. Replace it with the real agent image while keeping:
- **Service name:** `sre-agent`
- **Port:** `8080`
- **Namespace:** `sre-agent`

Grafana's contact point is pre-wired to `http://sre-agent.sre.svc.cluster.local:8080/alert`.

> **Note:** the stub uses namespace `sre`; the real agent uses `sre-agent`. Update `k8s/apps/sre-agent.yaml` destination namespace and the Grafana contact-point URL together.

---

## Alert rules

Provisioned via `k8s/apps/grafana.yaml` — no manual Grafana UI changes needed.

**Log-based (Loki datasource):**

| Rule | Condition | Severity |
|------|-----------|----------|
| Frontend 5xx burst | > 5 HTTP 5xx in 2 min | critical |
| Frontend 4xx burst | > 10 HTTP 4xx in 2 min | warning |
| Error logs in app namespaces | any `level=error/fatal` in 2 min | warning |

**Metric-based (Mimir/kube-state-metrics):**

| Rule | Condition | Severity |
|------|-----------|----------|
| Pod CrashLoopBackOff | `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}` for 1 min | critical |
| Pod image pull failure | `ErrImagePull` or `ImagePullBackOff` for 1 min | critical |
| Pod OOMKilled | last terminated reason = OOMKilled | critical |
| Pod stuck Pending | `phase="Pending"` for 2 min | warning |
| Pod not Ready | `kube_pod_status_ready{condition="false"}` for 3 min | warning |

All rules route to the `sre-agent` contact point (webhook POST).

---

## Fault injection scenarios

Apply with `bash scripts/scenarios.sh <name>`. Reset with `bash scripts/scenarios.sh cleanup`. Manifests live in `k8s/scenarios/` (not managed by Argo CD — no auto-heal).

| Scenario | What is injected | Expected alert |
|----------|-----------------|----------------|
| `healthy` | 200s only | No alert (baseline) |
| `error500` | HTTP 500 burst | Frontend 5xx burst |
| `error503` | HTTP 503 burst | Frontend 5xx burst |
| `notfound` | HTTP 404 burst | Frontend 4xx burst |
| `mixed` | 200 / 404 / 500 mix | Both 4xx and 5xx |
| `crashloop` | Container exits 1, "cannot connect to database" in logs | CrashLoopBackOff + Error logs |
| `bad-image` | Non-existent image tag | Pod image pull failure |
| `oom` | Memory limit 20 Mi (exceeds usage) | Pod OOMKilled |
| `pending` | Impossible CPU/memory request | Pod stuck Pending |
| `bad-probe` | Readiness probe → 404 | Pod not Ready |

---

## Moving to AKS

AKS replaces minikube/kind. Everything else — Argo CD, the app-of-apps, Helm charts, Alloy config — stays identical.

### 1. Provision the cluster

```bash
az group create --name rg-platform --location eastus
az aks create \
  --resource-group rg-platform \
  --name aks-platform \
  --node-count 2 \
  --node-vm-size Standard_D4s_v5 \
  --generate-ssh-keys \
  --enable-workload-identity \
  --enable-oidc-issuer \
  --network-plugin azure \
  --network-plugin-mode overlay
az aks get-credentials --resource-group rg-platform --name aks-platform
```

### 2. Install Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl apply -f k8s/root-app.yaml
```

### 3. Changes required in this repo

| File | Change |
|------|--------|
| `k8s/apps/loki.yaml` | Switch `storage.type` from `filesystem` to `azure` — set `storage_config.azure.account_name`, `account_key` (or Workload Identity), `container_name` |
| `k8s/apps/loki.yaml` | Increase `singleBinary.replicas` to 2+ or switch to distributed mode for HA |
| `k8s/apps/grafana.yaml` | Change datasource URLs to use real service FQDNs (they are already cluster-internal FQDNs, so no change if same namespace) |
| `k8s/apps/grafana.yaml` | Use an Ingress or Gateway API route instead of `port-forward` for external access |
| `k8s/apps/alloy-config.yaml` + `alloy.yaml` | Update `MIMIR_PUSH_URL`, `LOKI_PUSH_URL`, `TEMPO_OTLP` env vars in `values-platform.yaml` to point to the real stores |
| `scripts/bootstrap.sh` | Replace `minikube start` with `az aks create` + `az aks get-credentials` |

### 4. Persistent storage

AKS provides `managed-csi` (Azure Disk) and `azurefile-csi` (Azure File) StorageClasses.

- **Loki logs:** use Azure Blob via the `azure` storage backend (no PVC needed)
- **Grafana state:** add a PVC using `StorageClass: managed-csi` in the Grafana Helm values:
  ```yaml
  persistence:
    enabled: true
    storageClassName: managed-csi
    size: 10Gi
  ```
- **Mimir / Tempo / Loki (if file-based):** same `managed-csi` PVC pattern

### 5. Networking and ingress

Replace `port-forward` with a real ingress. Options:

**Option A — Gateway API (recommended, matches the platform repo pattern):**
```bash
# install Traefik as gateway controller
helm install traefik traefik/traefik -n traefik --create-namespace \
  --set "ports.web.expose.default=true" \
  --set "providers.kubernetesGateway.enabled=true"
```
Then add HTTPRoute resources pointing to `grafana`, `argocd-server`, etc.

**Option B — NGINX Ingress:**
```bash
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer
```
Add `Ingress` objects to each app's Helm values.

### 6. TLS

Use cert-manager with an ACME issuer (Let's Encrypt) or Azure Key Vault integration:
```bash
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --set crds.enabled=true
```
Add a `ClusterIssuer` for Let's Encrypt and annotate Ingress/HTTPRoute objects.

### 7. Image registry

Move container images to Azure Container Registry:
```bash
az acr create --resource-group rg-platform --name acrplatform --sku Basic
az aks update --resource-group rg-platform --name aks-platform --attach-acr acrplatform
```
Update image references in workload manifests from `ghcr.io/...` to `acrplatform.azurecr.io/...`.

### 8. GitHub Actions CI

Replace OIDC configuration:
```yaml
# .github/workflows/*.yml
permissions:
  id-token: write
  contents: read

- uses: azure/login@v2
  with:
    client-id: ${{ secrets.AZURE_CLIENT_ID }}
    tenant-id: ${{ secrets.AZURE_TENANT_ID }}
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

- run: az aks get-credentials --resource-group rg-platform --name aks-platform
```
Create a federated credential on a managed identity scoped to the AKS cluster for Argo CD Workflow and sre-agent pods.

### 9. Secrets management

Replace plaintext Kubernetes Secrets with Azure Key Vault + Secrets Store CSI driver or Sealed Secrets:
```bash
az aks enable-addons --addons azure-keyvault-secrets-provider \
  --resource-group rg-platform --name aks-platform
```

### 10. What stays the same

- `k8s/root-app.yaml` — unchanged (points to this repo, deploys to `kubernetes.default.svc`)
- All Helm chart versions and values (except storage backends)
- Alloy `config.alloy` — unchanged; only env vars differ
- Grafana alert rules, dashboards, contact points
- Argo CD app-of-apps pattern
- Fault injection scenarios

---

## Moving to EKS

EKS replaces minikube/kind. The app layer is identical to AKS; only the cloud primitives differ.

### 1. Provision the cluster

```bash
eksctl create cluster \
  --name platform \
  --region eu-west-1 \
  --nodegroup-name default \
  --node-type m5.xlarge \
  --nodes 2 \
  --with-oidc \
  --managed
aws eks update-kubeconfig --region eu-west-1 --name platform
```

### 2. Install Argo CD

Same as AKS — identical commands:
```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f k8s/root-app.yaml
```

### 3. Changes required in this repo

| File | Change |
|------|--------|
| `k8s/apps/loki.yaml` | Switch storage to S3: `storage.type: s3`, set `s3.bucketnames`, `s3.region`, `s3.endpoint` |
| `k8s/apps/loki.yaml` | Use IRSA (IAM Roles for Service Accounts) instead of access keys — annotate the ServiceAccount |
| `k8s/apps/alloy-config.yaml` + `alloy.yaml` | Update endpoint env vars to point to real Mimir/Loki/Tempo |
| `scripts/bootstrap.sh` | Replace `minikube start` with `eksctl create cluster` + `aws eks update-kubeconfig` |

### 4. Persistent storage

EKS provides `gp3` (EBS) via the EBS CSI driver and EFS for shared/multi-AZ storage.

```bash
# enable EBS CSI driver
eksctl create addon --name aws-ebs-csi-driver --cluster platform --region eu-west-1
```

- **Loki logs:** use S3 (`aws_access_key_id` / `aws_secret_access_key` or IRSA)
- **Grafana, Mimir, Tempo:** PVC with `StorageClass: gp3`
  ```yaml
  persistence:
    enabled: true
    storageClassName: gp3
    size: 10Gi
  ```

### 5. Networking and ingress

**Option A — AWS Load Balancer Controller (recommended):**
```bash
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=platform \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```
Annotate Services with `service.beta.kubernetes.io/aws-load-balancer-type: external` for NLB, or use ALB Ingress.

**Option B — Traefik with Gateway API** (same as the platform repo pattern):
```bash
helm install traefik traefik/traefik -n traefik --create-namespace \
  --set "ports.web.expose.default=true" \
  --set "providers.kubernetesGateway.enabled=true" \
  --set "service.type=LoadBalancer"
```

### 6. TLS

```bash
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --set crds.enabled=true
```
Use a `ClusterIssuer` with Let's Encrypt or ACM (via `external-dns` + Route 53).

### 7. Image registry

```bash
aws ecr create-repository --repository-name sre-agent --region eu-west-1
aws ecr get-login-password --region eu-west-1 | \
  docker login --username AWS --password-stdin <account>.dkr.ecr.eu-west-1.amazonaws.com
```
Update image references. Use IRSA to give pods pull access without storing credentials.

### 8. GitHub Actions CI

```yaml
permissions:
  id-token: write
  contents: read

- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::<account>:role/github-actions-platform
    aws-region: eu-west-1

- run: aws eks update-kubeconfig --region eu-west-1 --name platform
```
Create an IAM OIDC identity provider for `token.actions.githubusercontent.com` and an IAM role with a trust policy scoped to this repo.

### 9. Secrets management

Replace plaintext Secrets with AWS Secrets Manager + Secrets Store CSI driver:
```bash
helm install secrets-store-csi-driver secrets-store-csi-driver/secrets-store-csi-driver \
  -n kube-system --set syncSecret.enabled=true
helm install aws-secrets-manager-and-config-provider \
  aws-secrets-manager/secrets-store-csi-driver-provider-aws -n kube-system
```

### 10. What stays the same

- `k8s/root-app.yaml` — unchanged
- All Helm chart versions and values (except storage backends)
- Alloy `config.alloy` — unchanged; only env vars differ
- Grafana alert rules, dashboards, contact points
- Argo CD app-of-apps pattern
- Fault injection scenarios

---

## WSL / kind tips

**inotify limits (kube-proxy crash: "too many open files"):**
```bash
# in WSL as root — add to /etc/sysctl.conf for persistence
sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288
```

**Stale Prometheus/Mimir series after deleting pods:**
Dead pods leave their last-scraped metrics in Mimir until the retention window expires. They appear in Grafana as ghost series. They age out automatically; no action needed.

**Alloy config lives in `k8s-sre-platform`:**
`gitops/observability/alloy/config.alloy` is the single Alloy pipeline definition shared by all clusters. Changes there affect every cluster on the next Argo CD sync. Per-cluster differences (endpoints, cluster label) are in `values-<cluster>.yaml`.
