# foobar-api: Secure K8S Deployment via Traefik

## Summary

This POC containerizes and deploys the [`foobar-api`](https://github.com/containous/foobar-api) (a Go-based whoami service) into a K8S environment, exposing it securely over HTTPS using **Traefik** as the edge router.

Certificates are managed via a **Persistent Volume Claim (PVC)**, fulfilling the requirement for filesystem-based certificate lifecycle management. The solution emphasizes **Zero Trust** networking, **SRE observability**, and fully automated deployment through a single `make all` command.

---

## Architecture Overview

```
[Client] --HTTPS--> [Traefik :443] --HTTPS--> [foobar-api :8080]
                    (PVC cert)                 (PVC cert, insecureSkipVerify)
                         |
                    [NetworkPolicy]
                    (only Traefik -> API)
```

**Traffic flow:**
1. Client connects to `https://foobar.local` — TLS terminated by Traefik using the PVC-stored cert
2. Traefik forwards to the foobar-api pod over HTTPS (port 8080), skipping backend cert verification via `ServersTransport`
3. The API pod serves TLS using the same PVC-mounted cert at the hardcoded path `/cert/cert.pem` and `/cert/key.pem`
4. A `NetworkPolicy` restricts ingress to the API pods exclusively from Traefik pods

---

## Architectural Decisions

### 1. TLS via PVC File Provider

The POC uses certificates in a PVC. Traefik's **file provider** watches a mounted directory for cert changes, enabling external rotation (e.g., via a sidecar or legacy PKI process) without K8S Secret updates or redeployment.

- Traefik mounts the PVC at `/certs/` and watches `/config/dynamic.yaml` for TLS configuration
- The foobar-api binary hardcodes `/cert/cert.pem` and `/cert/key.pem` as its cert paths — these are mounted via `subPath` from the same PVC

### 2. Traefik CRD Provider over Ingress Annotations

It seems Traefik v3 **removed** support for the `traefik.ingress.kubernetes.io/service.serversscheme` and `service.serverstransport` ingress annotations. Attempting to use them results in Traefik silently ignoring the backend scheme and routing HTTP to an HTTPS backend.

The solution uses native Traefik CRDs:
- `IngressRoute` — defines routing rules with explicit `scheme: https` and `serversTransport` reference
- `ServersTransport` — configures `insecureSkipVerify: true` to trust the backend's self-signed cert
- CRD definitions are pinned to v3.0.0 and applied before Traefik starts

### 3. Zero Trust Networking

- The foobar-api `Service` is `ClusterIP` — not reachable from outside the cluster
- A `NetworkPolicy` allows ingress to API pods **only** from pods labelled `app: traefik`
- The Dockerfile runs as a non-root user (`appuser`, UID 1000) with a minimal Alpine base
- No secrets are stored in the image or in K8S secrets — certs live exclusively in the PVC

### 4. SRE Observability

- `livenessProbe` and `readinessProbe` on `/health` (HTTPS) with staggered delays ensure the scheduler only routes traffic to healthy instances
- Traefik runs at `--log.level=DEBUG` for full visibility during development
- `--api.insecure=true` exposes the Traefik dashboard on port 8080 for runtime inspection
- 2 API replicas provide basic availability and allow observable load balancing via `X-Forwarded-Server` headers

### Why These Choices Were Made

**Raw manifests over Helm**
Traefik's official Helm chart is built around K8S secrets and cert-manager/ACME for TLS. The PVC-based certificate requirement puts you immediately at odds with those opinions — you'd spend more effort overriding the chart's defaults than the chart saves you. Raw manifests gave full, explicit control over init containers, volume mounts, file provider config, and CRD apply order, with zero indirection. Helm is the right call for a production Traefik deployment with standard TLS lifecycle management; it's the wrong call when the goal is transparency and non-standard cert handling.

**External cert generation over in-cluster**
Certs could have been generated inside the cluster via an `initContainer` on the Traefik pod, removing the `openssl` host dependency and the helper pod entirely. That's a valid and simpler approach for a POC. The external generation pattern was chosen deliberately because it better mirrors real enterprise PKI: certificates come from a controlled CA, are rotated independently of the workload, and are injected into the cluster rather than self-signed at runtime by the router. The PVC acts as the handoff point between the external cert lifecycle and the cluster.

**PVC over K8S Secrets for certificates**
K8S Secrets are base64-encoded at rest by default — not encrypted unless you've configured envelope encryption, which most clusters don't have enabled out of the box. A PVC with proper filesystem permissions (`600` on the key, owned by UID 1000) is at least as safe in a local environment, and more importantly it satisfies the requirement for filesystem-based cert management. It also enables Traefik's file provider hot-reload: rotate the cert on the PVC and Traefik picks it up without a restart.

**ClusterIP service with NetworkPolicy over direct exposure**
The foobar-api Service is intentionally `ClusterIP` — invisible outside the cluster. The `NetworkPolicy` restricts ingress to API pods exclusively from pods labelled `app: traefik`, so even within the cluster no other workload can reach the API directly. This follows a Zero Trust posture: every hop is explicit and least-privilege, rather than relying on namespace isolation alone.

**Non-root container with minimal base image**
The Dockerfile uses a two-stage build: a `golang:alpine` builder followed by a minimal `alpine` runtime with a dedicated non-root `appuser` (UID 1000). No shell, no package manager, no build tools in the final image. This reduces attack surface and ensures the binary runs with the minimum privileges needed — relevant here because the app serves TLS directly and holds cert material on its filesystem.

**Traefik CRDs over Ingress annotations**
Traefik v3 silently dropped support for the `service.serversscheme` and `service.serverstransport` Ingress annotations that v2 supported. Using native `IngressRoute` and `ServersTransport` CRDs instead is not just a workaround — it's the correct v3 architecture. CRDs are first-class Traefik objects with full schema validation, explicit backend scheme control, and no silent failures. The Ingress annotation approach was always a leaky abstraction.

---

## Project Structure

```
.
├── Dockerfile                        # multi-stage build, non-root user
├── Makefile                          # full lifecycle automation
├── k8s/
│   ├── base/
│   │   ├── namespace.yaml            # foobar-namespace isolation boundary
│   │   ├── deployment.yaml           # API deployment (2 replicas, PVC cert mounts)
│   │   ├── service.yaml              # ClusterIP service on port 8080
│   │   ├── pvc.yaml                  # certificate storage (128Mi, local-path)
│   │   └── network-policy.yaml       # allow ingress only from Traefik
│   └── traefik/
│       ├── rbac.yaml                 # ServiceAccount + ClusterRole (all traefik.io resources)
│       ├── crds.yaml                 # Traefik CRD definitions (v3.0.0, fetched at deploy time)
│       ├── traefik-deployment.yaml   # Traefik with CRD+file+ingress providers
│       ├── traefik-service.yaml      # LoadBalancer on :80 and :443
│       ├── dynamic-conf.yaml         # file provider: TLS cert + insecureSkipVerify transport
│       ├── serverstransport.yaml     # ServersTransport CRD: insecureSkipVerify for backend
│       └── ingressroute.yaml         # IngressRoute CRD: HTTPS routing to foobar-service
└── scripts/
    └── generate-certs.sh             # Day-0 cert generation and PVC population
```

---

## Prerequisites

- A running K8S cluster (tested on **Rancher Desktop**; compatible with Kind, Minikube)
- `kubectl`, `docker`, and `openssl` installed
- Rancher Desktop's built-in Traefik **disabled** (to avoid port conflicts)
- Add to `/etc/hosts`:
  ```
  127.0.0.1   foobar.local
  ```

---

## Deployment

### Full deployment

```bash
make all
```

This runs in order: build image → create namespace → generate certs → populate PVC → install CRDs → deploy Traefik → wait for readiness → apply IngressRoute → deploy API.

### Verify

```bash
# Whoami response with request headers
curl -k https://foobar.local --resolve foobar.local:443:127.0.0.1

# JSON API response
curl -k https://foobar.local/api --resolve foobar.local:443:127.0.0.1

# Health check (returns 200)
curl -k https://foobar.local/health -w "%{http_code}" --resolve foobar.local:443:127.0.0.1
```

* Example output from `/api`:
```json
{
  "hostname": "foobar-api-xxxxxx-xxxx",
  "ip": [
    "127.0.0.1",
    "::1",
    "##.##.##.##",
    "abc0::abc0:abc:abc0:abc0"
  ],
  "headers": {
    "Accept": [
      "*/*"
    ],
    "Accept-Encoding": [
      "gzip"
    ],
    "User-Agent": [
      "curl/8.7.1"
    ],
    "X-Forwarded-For": [
      "##.##.##.##"
    ],
    "X-Forwarded-Host": [
      "foobar.local"
    ],
    "X-Forwarded-Port": [
      "443"
    ],
    "X-Forwarded-Proto": [
      "https"
    ],
    "X-Forwarded-Server": [
      "traefik-xxxxxx-xxxx"
    ],
    "X-Real-Ip": [
      "##.##.##.##"
    ]
  },
  "url": "/api",
  "host": "foobar.local",
  "method": "GET"
}
```

Or... you can use `test` target from Makefile for full testing
```bash
make test
```

* Example output from `make test`:
```text
--- Waiting for API to be ready ---
deployment "foobar-api" successfully rolled out
--- Running Tests ---
--- Waiting for Traefik to sync endpoints ---
# api
--- API test endpoint is working ---
# data (body size)
--- Data test endpoint is working ---
# data (attachment download)
--- Data test endpoint with attachment is working ---
--- Data test endpoint with attachment is correct size ---
# health
--- Health endpoint is healthy ---
# websocket (echo)
echo
--- WebSocket test passed ---
```

### Teardown

```bash
make clean
```

---

## Operational Checks

**Pod status:**
```bash
kubectl get pods -n foobar-namespace
```

**Traefik logs (filtered):**
```bash
kubectl logs -n foobar-namespace -l app=traefik | grep -v "ServersTransportTCP\|reflector\|Endpoints"
```

**Traefik dashboard (active router inspection):**
```bash
kubectl port-forward -n foobar-namespace deploy/traefik 8080:8080
# Then open: http://localhost:8080/dashboard/
# Or: curl -s http://localhost:8080/api/http/routers | python3 -m json.tool
```

**Verify certs in PVC:**
```bash
kubectl run pvc-check --image=alpine -n foobar-namespace --restart=Never --rm -it \
  --overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"traefik-certs-pvc"}}],"containers":[{"name":"check","image":"alpine","command":["ls","-l","/certs"],"volumeMounts":[{"name":"data","mountPath":"/certs"}]}]}}'
```

---

## Health Endpoint Instrumentation

The `/health` endpoint is both a liveness probe target and a live control plane for failure simulation. It supports `GET` to check status and `POST` to manually set the response code, which makes it useful for testing K8S restart behavior without touching deployments.

### How It Works

By default, `GET /health` returns `200 OK`. A `POST` request with a status code in the body overrides that response until the pod restarts or the code is reset:

```bash
# Check current health status
curl -k https://foobar.local/health

# Force the endpoint to return 500
curl -k -X POST -d "500" https://foobar.local/health

# Restore to healthy
curl -k -X POST -d "200" https://foobar.local/health
```

### Simulating a Liveness Probe Failure

Once the endpoint returns 500, the kubelet will detect the failure after `failureThreshold` consecutive failed checks (3 by default, every 10 seconds — so roughly 30 seconds):

```bash
# Poison the health endpoint
curl -k -X POST -d "500" https://foobar.local/health

# Watch the probe fail and the container get killed and restarted
kubectl get pods -n foobar-namespace -w

# Confirm the event in pod description
kubectl describe pod -l app=foobar-api -n foobar-namespace | grep -iE "liveness|unhealthy|killing"
```

You should see output like:

```
Warning  Unhealthy  15s (x3 over 35s)  kubelet  Liveness probe failed: HTTP probe failed with statuscode: 500
Normal   Killing    15s                kubelet  Container foobar-api failed liveness probe, will be restarted
```

After the container restarts, the override is gone and health returns to `200` automatically.

### Load Testing the Health Endpoint

To run 500 sequential requests and observe how the endpoint behaves under load:

```bash
# 500 sequential GET requests, print only HTTP status codes
for i in $(seq 1 500); do
  curl -sk -o /dev/null -w "%{http_code}\n" https://foobar.local/health
done | sort | uniq -c
```

To run them with concurrency using `xargs`:

```bash
# 500 requests, 10 at a time in parallel
seq 1 500 | xargs -P 10 -I {} \
  curl -sk -o /dev/null -w "%{http_code}\n" https://foobar.local/health \
| sort | uniq -c
```

Both commands produce a summary like:

```
498 200
  2 000
```

Where `000` indicates a connection that didn't complete — useful for spotting pod restarts or Traefik sync lag mid-test.

### Combining Load and Failure Injection

A more realistic test: start a load run, inject a failure mid-flight, and observe how quickly Kubernetes reacts and how Traefik handles the window between probe failure and pod removal from the service endpoints:

```bash
# terminal 1 — continuous load
while true; do
  curl -sk -o /dev/null -w "%{http_code}\n" https://foobar.local/health
  sleep 0.2
done

# terminal 2 — inject failure after a few seconds
sleep 5 && curl -k -X POST -d "500" https://foobar.local/health
```

Watch the status codes in terminal 1 shift from `200` to `500` as the probe poisons, then drop to `000` or `502` briefly while Traefik drains the unhealthy pod, then return to `200` once the restarted pod passes its readiness check. That window between liveness failure and endpoint removal is the gap where real traffic would be affected — and it's exactly what a readiness probe is designed to close.

### Using /health as a Readiness Gate

The readiness probe hits `/` rather than `/health` in this setup, which means poisoning `/health` triggers a liveness restart but does not immediately pull the pod from the load balancer rotation. If you want to test graceful traffic draining instead of forced restart, change the readiness probe to target `/health` as well:

```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8080
    scheme: HTTPS
```

With this configuration, a `POST 500` to `/health` will mark the pod `NotReady`, remove it from the Service endpoints, and stop new traffic — without killing the container. This is the correct pattern for graceful degradation: signal unreadiness first, let traffic drain, then fix or restart.

* Adjust the `--resolve` flag or `-k` as needed to match your local cert setup.

---

Here's a clean section for the README:

---

## Observability: Prometheus Metrics

Traefik exposes a native Prometheus metrics endpoint that requires no additional tooling or changes to the application stack. Enabling it is purely additive — two arguments to the Traefik deployment and one port addition to the service.

### Enabling the Metrics Endpoint

Add the following to Traefik's `args` in `k8s/traefik/traefik-deployment.yaml`:

```yaml
- "--metrics.prometheus=true"
- "--entrypoints.metrics.address=:9100"
- "--metrics.prometheus.entryPoint=metrics"
```

Then expose port 9100 on the Traefik service in `k8s/traefik/traefik-service.yaml`:

```yaml
- name: metrics
  port: 9100
  targetPort: 9100
  protocol: TCP
```

### Scraping the Metrics

After redeploying Traefik, the metrics endpoint is available at `:9100/metrics`. You can inspect it directly with a port-forward:

```bash
kubectl port-forward svc/traefik 9100:9100 -n foobar-namespace
curl http://localhost:9100/metrics | grep traefik_
```

### Key Metrics to Watch

All metrics are labeled by router and service name, which in this setup correspond to the `foobar-ingressroute` and `foobar-service` identifiers defined in the IngressRoute.

**Request rates and status codes:**
```bash
# Total requests by service and status code
curl -s http://localhost:9100/metrics | grep traefik_service_requests_total

# Useful during health endpoint load tests to confirm
# the distribution of 200s vs 500s reaching the backend
```

**Request duration (latency):**
```bash
# Histogram buckets for p50/p95/p99 estimation
curl -s http://localhost:9100/metrics | grep traefik_service_request_duration
```

**Open connections:**
```bash
# Active connections at the entrypoint level
curl -s http://localhost:9100/metrics | grep traefik_entrypoint_open_connections
```

### Connecting a Prometheus Instance

If you want to persist and query metrics over time, point any Prometheus instance at the endpoint with a minimal scrape config:

```yaml
scrape_configs:
  - job_name: traefik
    static_configs:
      - targets: ['traefik.foobar-namespace.svc.cluster.local:9100']
```

From there, a Grafana instance with the community Traefik dashboard will give you request rate, error rate, and latency panels with no custom PromQL required.

---

## Troubleshooting: What Went Wrong and Why

This section documents my debugging journey from a broken deployment to a working one.

### Bug 1 — Binary crash: `You need to provide a certificate`

**Symptom:** `CrashLoopBackOff`, logs show `You need to provide a certificate` immediately on start.

**Root cause:** The `foobar-api` binary hardcodes `os.Stat("/cert/cert.pem")` and `os.Stat("/cert/key.pem")` — these paths are not configurable via flags or environment variables. Initial attempts mounted certs at `/home/appuser/cert.pem` (wrong directory) and used symlinks (failed due to read-only filesystem).

**Fix:** Mount the PVC files directly to `/cert/cert.pem` and `/cert/key.pem` using K8S `subPath` volume mounts:
```yaml
volumeMounts:
  - name: certs-volume
    mountPath: /cert/cert.pem
    subPath: tls.crt
    readOnly: true
  - name: certs-volume
    mountPath: /cert/key.pem
    subPath: tls.key
    readOnly: true
```

---

### Bug 2 — Traefik routing HTTP to HTTPS backend: `Client sent an HTTP request to an HTTPS server`

**Symptom:** HTTP 400 from the API pod. Traefik logs show `target=http://10.42.x.x:8080`.

**Root cause:** Traefik v3 **silently ignores** the `traefik.ingress.kubernetes.io/service.serversscheme: https` Ingress annotation. Despite the annotation being present, Traefik builds `http://` backend URLs.

**Fix:** Replace the `Ingress` object with a native `IngressRoute` CRD and a `ServersTransport` CRD:
```yaml
# IngressRoute explicitly sets scheme and transport
services:
  - name: foobar-service
    port: 8080
    scheme: https
    serversTransport: insecure-transport
```

---

### Bug 3 — Traefik CRDs not installed: `no matches for kind "ServersTransport"`

**Symptom:** `make all` fails with `resource mapping not found`.

**Root cause:** Traefik CRD definitions are not bundled with the Traefik Docker image — they must be applied to the cluster separately before any CRD resources are created.

**Fix:** Added a `curl` + `kubectl apply` step in the Makefile to fetch and apply the v3.0.0 CRD manifest before deploying Traefik:
```makefile
[ -f k8s/traefik/crds.yaml ] || curl -o k8s/traefik/crds.yaml https://raw.githubusercontent.com/traefik/traefik/v3.0.0/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
kubectl apply -f k8s/traefik/crds.yaml
```

---

### Bug 4 — RBAC missing `serverstransporttcps`: IngressRoute silently dropped

**Symptom:** HTTP 404 from Traefik. No routes in `GET /api/http/routers`. Traefik logs only show `forbidden: cannot list resource "serverstransporttcps"` on repeat.

**Root cause:** The missing RBAC permission for `serverstransporttcps` caused Traefik's CRD reflector to enter a fatal backoff loop, which **silently prevented all CRD resources from being processed** — including the IngressRoute. This was the hardest bug to diagnose because the error message pointed to TCP transports while the real victim was HTTP routing.

**Fix:** Add all `traefik.io` resources to the ClusterRole, including `serverstransporttcps`:
```yaml
- apiGroups: ["traefik.io"]
  resources:
    - ingressroutes
    - serverstransports
    - serverstransporttcps   # this missing entry broke everything
    - tlsoptions
    - tlsstores
    - traefikservices
    # ... etc
  verbs: ["get", "list", "watch"]
```

---

### Bug 5 — IngressRoute `tls: {}` skipped when old Ingress coexists

**Symptom:** After switching to IngressRoute, two competing routes existed — one from the old `Ingress` object routing `http://` to the backend, one from the `IngressRoute` routing `https://`. The HTTP route won.

**Fix:** Remove the `Ingress` object and the `kubectl apply -f traefik-config.yaml` step from the Makefile entirely. The `IngressRoute` is the single source of truth for routing.

---

### Bug 6 — IngressRoute with `tls: {}` and no `secretName` skipped

**Symptom:** Traefik logs show `No secret name provided > Skipping K8S event kind *v1alpha1.IngressRoute`.

**Root cause:** When `tls:` is present in an IngressRoute but has no `secretName`, the CRD provider skips the route. However, removing `tls: {}` entirely causes the router to be registered without TLS, resulting in 404 for HTTPS requests.

**Fix:** Keep `tls: {}` in the IngressRoute. The CRD provider accepts this when there is no conflicting `Ingress` object for the same host. The default TLS store (populated by the file provider from the PVC cert) is used automatically.

---

### Bug 7 — IngressRoute applied before Traefik is ready

**Symptom:** Intermittent 404 after clean deployments. Traefik processes the IngressRoute during startup but misses it if applied too early.

**Fix:** Gate IngressRoute application on `kubectl rollout status`:
```makefile
kubectl rollout status deployment/traefik -n $(NAMESPACE) --timeout=120s
kubectl apply -f k8s/traefik/ingressroute.yaml
```

---

## Future Considerations

- **Key Management:** Migration from PVC-stored certs to a KMS/Vault integration using `External Secrets Operator`
- **Autoscaling:** Add a `HorizontalPodAutoscaler` based on Traefik request-rate metrics
- **Observability:** Wire Prometheus scraping annotations on pods; add Traefik access log structured output. Described, but not implemented. 
- **mTLS:** The binary supports mutual TLS via a `-ca` flag — a CA cert in the PVC would enable full mTLS between Traefik and the API
- **StorageClass portability:** Replace `local-path` storageClassName with `""` (default) for cloud portability. Note that `local-path` was used due to Rancher Desktop constraints. 