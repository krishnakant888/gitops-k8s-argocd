# gitops-k8s-argocd

Local Kubernetes (minikube) with Argo CD, Loki, Promtail and Grafana, all managed from Git.

## One-time bootstrap
1. Push this repo to Git and set `repoURL` in `k8s/root-app.yaml`.
2. Install docker, minikube, kubectl.
3. `bash scripts/bootstrap.sh`

After that, add or change manifests in `k8s/apps/` and push; Argo CD syncs them.

## Stack
- `k8s/apps/loki.yaml` – Loki (single binary, filesystem storage)
- `k8s/apps/promtail.yaml` – ships pod logs to Loki
- `k8s/apps/grafana.yaml` – Grafana with the Loki data source provisioned

Query logs from Grafana (Explore). An SRE agent can call Loki directly:
`http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/query_range`.
