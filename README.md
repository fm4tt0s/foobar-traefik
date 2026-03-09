# foobar-api: Secure Kubernetes Deployment via Traefik

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

- A running Kubernetes cluster (tested on **Rancher Desktop**; compatible with Kind, Minikube)
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
curl -k https://foobar.local/health --resolve foobar.local:443:127.0.0.1
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

## Troubleshooting: What Went Wrong and Why

This section documents the real debugging journey from a broken deployment to a working one.

### Bug 1 — Binary crash: `You need to provide a certificate`

**Symptom:** `CrashLoopBackOff`, logs show `You need to provide a certificate` immediately on start.

**Root cause:** The `foobar-api` binary hardcodes `os.Stat("/cert/cert.pem")` and `os.Stat("/cert/key.pem")` — these paths are not configurable via flags or environment variables. Initial attempts mounted certs at `/home/appuser/cert.pem` (wrong directory) and used symlinks (failed due to read-only filesystem).

**Fix:** Mount the PVC files directly to `/cert/cert.pem` and `/cert/key.pem` using Kubernetes `subPath` volume mounts:
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
curl -o k8s/traefik/crds.yaml \
  https://raw.githubusercontent.com/traefik/traefik/v3.0.0/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
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
    - serverstransporttcps   # ← this missing entry broke everything
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

**Symptom:** Traefik logs show `No secret name provided > Skipping Kubernetes event kind *v1alpha1.IngressRoute`.

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

- **Key Management:** Migrate from PVC-stored certs to a KMS/Vault integration using `External Secrets Operator`
- **Autoscaling:** Add a `HorizontalPodAutoscaler` based on Traefik request-rate metrics
- **Observability:** Wire Prometheus scraping annotations on pods; add Traefik access log structured output
- **mTLS:** The binary supports mutual TLS via a `-ca` flag — a CA cert in the PVC would enable full mTLS between Traefik and the API
- **StorageClass portability:** Replace `local-path` storageClassName with `""` (default) for cloud portability