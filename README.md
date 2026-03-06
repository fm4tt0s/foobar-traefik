# Foobar-API: Secure Kubernetes Deployment

## Summary

This project demonstrates the containerization and deployment of the `foobar-api` (Go-based) into a K8S env. The solution emphasizes **Zero Trust** security, **SRE observability**, and a specialized handling of TLS certificates via **Persistent Volume Claims (PVC)**.

The architecture uses **Traefik Proxy** as the edge router, providing automated TLS termination and traffic management.

---

## Architectural Decisions

### 1. TLS Termination via File Provider (PVC)

While standard K8S deployments usually leverage `secrets` or `cert-manager` for certificate management, this solution implements a **Traefik File Provider**.

* **Reasoning:** By mounting a PVC to the Traefik deployment, we provide a mechanism for external certificate rotation (e.g., via a sidecar or legacy PKI process) without requiring Kubernetes API Secret updates.
* **Implementation:** Traefik is configured to watch `/certs/` on the mounted volume for `tls.crt` and `tls.key`.

### 2. Networking & Security (Zero Trust)

* **ClusterIP Service:** The API is exposed internally via a `ClusterIP` service. This ensures the API is **not** reachable directly from outside the cluster, forcing all traffic through the Traefik Ingress.
* **NetworkPolicy:** A strict Ingress NetworkPolicy is applied to the `foobar-namespace`, allowing traffic to the API pods **only** if it originates from the Traefik Ingress Controller.
* **Non-Root Execution:** The Dockerfile utilizes a multi-stage build and a non-privileged user (`appuser`) to reduce the container's attack surface.

### 3. SRE & Observability (Always-On Design)

* **Health Probes:** I have implemented `livenessProbe` and `readinessProbe` with staggered `initialDelaySeconds`. This ensures the scheduler only routes traffic to healthy instances and automatically restarts failing pods.
* **Resource Constraints:** Every deployment includes CPU/Memory `requests` and `limits` to prevent noisy-neighbor effects and ensure predictable performance.
* **Metrics:** The pods are annotated for Prometheus scraping, enabling immediate visibility into traffic patterns and latency.

---

## Project Structure

```text
.
├── Dockerfile              # multi-stage build for minimal footprint
├── Makefile                # automation for the entire deployment lifecycle
├── k8s/
│   ├── base/               # core Application Manifests
│   │   ├── deployment.yaml # API Deployment (2 replicas)
│   │   ├── service.yaml    # internal ClusterIP service
│   │   ├── pvc.yaml        # certificate storage
│   │   └── network-policy.yaml
│   └── traefik/            # ingress Infrastructure
│       ├── rbac.yaml       # controller permissions
│       ├── traefik-deployment.yaml
│       ├── traefik-config.yaml #ingress rules
│       └── dynamic-conf.yaml   # TLS file provider mapping
└── scripts/
    └── generate-certs.sh   # automated self-signed cert generation

```

---

## Deployment Procedure

### Local Testing
When testing it locally, you need to add this to `/etc/hosts` so you can see the TLS cert in action.
```text
127.0.0.1 foobar.local

```

You can edit the file directly (sudo vi/emacs/ed/whatever) or simply run:
```bash
sudo tee -a /etc/hosts <<< "127.0.0.1 foobar.local"

```

### Prerequisites

* A running Kubernetes cluster (`Kind`, `Minikube`, or Cloud-managed).
* `kubectl` and `openssl` installed.

### Execution

The included `Makefile` handles the orchestration of infrastructure and application layers.

1. **Full Deployment:**
```bash
make all

```

*This will: build the image -> create namespace -> generate certs -> populate PVC -> deploy Traefik -> deploy API.*

2. **Verification:**
Once deployed, the API is accessible via HTTPS. You can verify the secure connection using:
```bash
curl -k https://foobar.local --resolve foobar.local:443:127.0.0.1

```


3. **Cleanup:**
To tear down the environment:
```bash
make clean

```

---

## Future Considerations

* **Key Management:** Transition from PVC-stored certificates to a native **KMS/Vault** integration using `External Secrets Operator`.
* **Autoscaling:** Implement a `HorizontalPodAutoscaler` (HPA) based on custom Traefik metrics (request-per-second) rather than just CPU/RAM.
