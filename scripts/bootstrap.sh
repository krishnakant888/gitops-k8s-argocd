#!/usr/bin/env bash
# One-time bootstrap: local minikube cluster + Argo CD + root app.
# Everything after this is driven by Git (k8s/apps/).
# Requires: docker, minikube, kubectl.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE=gitops

minikube start --driver=docker --profile "$PROFILE" --cpus=4 --memory=6144
kubectl config use-context "$PROFILE"

kubectl get ns argocd >/dev/null 2>&1 || kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

kubectl apply -f "$ROOT/k8s/root-app.yaml"

echo
echo "Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
echo
echo "Argo CD UI: kubectl -n argocd port-forward svc/argocd-server 8080:443  (https://localhost:8080, user: admin)"
echo "Grafana UI: kubectl -n monitoring port-forward svc/grafana 3000:80    (http://localhost:3000)"
