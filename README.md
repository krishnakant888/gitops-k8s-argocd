# gitops-k8s-argocd

Local Kubernetes (minikube) with Argo CD, Loki, Alloy, Prometheus and Grafana, all managed from Git.

## One-time bootstrap
1. Push this repo to Git and set `repoURL` in `k8s/root-app.yaml`.
2. Install docker, minikube, kubectl.
3. `bash scripts/bootstrap.sh`

After that, add or change manifests in `k8s/apps/` and push; Argo CD syncs them.

## Stack
- `k8s/apps/loki.yaml` – Loki (single binary, filesystem storage)
- `k8s/apps/alloy.yaml` – Grafana Alloy ships pod logs to Loki
- `k8s/apps/grafana.yaml` – Grafana with the Loki data source provisioned

Query logs from Grafana (Explore). An SRE agent can call Loki directly:
`http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/query_range`.

## WSL note
If kube-proxy crashes with `too many open files`, raise the inotify limits (as root in WSL) and restart the cluster pods:

    sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288

## Frontend and SRE scenarios
`k8s/workloads/frontend/` is a stateless nginx app (2 replicas, non-root, read-only filesystem, JSON logs) deployed by `k8s/apps/frontend.yaml`.
Fault injection for testing an SRE agent: see `docs/SCENARIOS.md` and `scripts/scenarios.sh`.
