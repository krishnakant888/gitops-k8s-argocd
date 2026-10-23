#!/usr/bin/env bash
# Fault-injection scenarios to test an SRE agent. Run in WSL against the minikube cluster.
# Usage: scripts/scenarios.sh <scenario|list|status|cleanup> [count]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS=scenarios
N="${2:-60}"

load() { # <path> <count>
  kubectl -n frontend run "load-$RANDOM" --rm -i --restart=Never --image=curlimages/curl -- \
    sh -c "for i in \$(seq 1 $2); do curl -s -o /dev/null -w '%{http_code}\n' http://frontend$1; done" | sort | uniq -c
}

apply() {
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
  kubectl apply -f "$ROOT/k8s/scenarios/$1.yaml"
}

case "${1:-list}" in
  list)
    cat <<TXT
Traffic scenarios (frontend namespace):
  error500   burst of HTTP 500 (app errors)
  error503   burst of HTTP 503 (unavailable)
  notfound   burst of HTTP 404
  mixed      200s + 404s + 500s
  healthy    only 200s (baseline, agent should report no issue)
Workload scenarios (scenarios namespace):
  crashloop  CrashLoopBackOff, fatal error in logs
  bad-image  ImagePullBackOff / ErrImagePull
  oom        OOMKilled (20Mi limit)
  pending    Unschedulable pod (impossible resource request)
  bad-probe  Running but never Ready (readiness probe 404)
Other: status | cleanup
TXT
    ;;
  error500)  load /_scenarios/error500 "$N" ;;
  error503)  load /_scenarios/error503 "$N" ;;
  notfound)  load /_scenarios/notfound "$N" ;;
  healthy)   load / "$N" ;;
  mixed)     load / "$N"; load /_scenarios/notfound "$((N/3))"; load /_scenarios/error500 "$((N/3))" ;;
  crashloop|bad-image|oom|pending|bad-probe) apply "$1" ;;
  status)
    kubectl -n "$NS" get pods 2>/dev/null || true
    kubectl -n frontend get pods ;;
  cleanup)
    kubectl delete namespace "$NS" --ignore-not-found ;;
  *) echo "unknown scenario: $1 (try: list)" >&2; exit 1 ;;
esac
