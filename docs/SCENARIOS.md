# SRE agent test scenarios

Run from WSL: `bash scripts/scenarios.sh <name>`. Reset with `bash scripts/scenarios.sh cleanup`.
Workload scenarios live in `k8s/scenarios/` and deploy to the `scenarios` namespace, which Argo CD does not manage, so nothing is auto-healed.

Frontend logs are JSON on stdout (`level`, `request_id`, `method`, `uri`, `status`, `duration_s`).
In Grafana Explore: `{namespace="frontend"} | json | status >= 500`.

| Scenario | Injects | Signal | Expected agent finding |
|---|---|---|---|
| healthy | 200s only | no errors | No issue; must not raise a false alarm |
| error500 | HTTP 500 burst | `level="error"`, `status=500` in Loki | Elevated 5xx on `frontend`; app error, not infra |
| error503 | HTTP 503 burst | `status=503` | Service unavailable errors on `frontend` |
| notfound | HTTP 404 burst | `level="warn"`, `status=404` | Client errors / bad route, lower severity than 5xx |
| mixed | 200/404/500 mix | all of the above | Correct error ratio, ranks 5xx above 4xx |
| crashloop | container exits 1 | `CrashLoopBackOff`, "cannot connect to database" in logs | Crash loop; root cause from the log line |
| bad-image | non-existent tag | `ErrImagePull` / `ImagePullBackOff` events | Bad image tag, no logs available |
| oom | exceeds 20Mi | `OOMKilled`, exit code 137 | Memory limit too low |
| pending | impossible request | `FailedScheduling` event | Insufficient resources / unschedulable |
| bad-probe | readiness 404 | Running, 0/1 Ready, probe failures | Probe misconfigured; not a crash |

Pass criteria per scenario: the agent names the right workload, the right category, a plausible root cause, and does not blame unrelated services.
