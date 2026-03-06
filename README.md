# 🚀 Foobar-API: Secure Kubernetes Deployment

## Executive Summary

This project demonstrates the containerization and deployment of the `foobar-api` (Go-based) into a Kubernetes environment. The solution emphasizes **Zero Trust** security, **SRE observability**, and a specialized handling of TLS certificates via **Persistent Volume Claims (PVC)** to meet specific organizational constraints.

The architecture uses **Traefik Proxy** as the Edge Router, providing automated TLS termination and traffic management.

---

## 🏗 Architectural Decisions

### 1. TLS Termination via File Provider (PVC)

While standard Kubernetes deployments typically leverage `Secrets` or `cert-manager` for certificate management, this solution implements a **Traefik File Provider**.

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

## 📂 Project Structure

```text
.
├── Dockerfile              # Multi-stage build for minimal footprint
├── Makefile                # Automation for the entire deployment lifecycle
├── k8s/
│   ├── base/               # Core Application Manifests
│   │   ├── deployment.yaml # API Deployment (2 replicas)
│   │   ├── service.yaml    # Internal ClusterIP service
│   │   ├── pvc.yaml        # Certificate storage
│   │   └── network-policy.yaml
│   └── traefik/            # Ingress Infrastructure
│       ├── rbac.yaml       # Controller permissions
│       ├── traefik-deployment.yaml
│       ├── traefik-config.yaml # Ingress rules
│       └── dynamic-conf.yaml   # TLS File Provider mapping
└── scripts/
    └── generate-certs.sh   # Automated self-signed cert generation

```

---

## 🚀 Deployment Procedure

### Local Testing
When testing it locally, you need to add this to **/etc/hosts** so you can see the TLS cert in action.
```text
127.0.0.1 foobar.local

```

### Prerequisites

* A running Kubernetes cluster (`Kind`, `Minikube`, or Cloud-managed).
* `kubectl` and `openssl` installed.

### Execution

The included `Makefile` handles the orchestration of infrastructure and application layers in the correct order.

1. **Full Deployment:**
```bash
make all

```


*This will: Build the image -> Create Namespace -> Generate Certs -> Populate PVC -> Deploy Traefik -> Deploy API.*
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

## 📈 Future Considerations

* **Key Management:** Transition from PVC-stored certificates to a native **KMS/Vault** integration using `External Secrets Operator`.
* **Autoscaling:** Implement a `HorizontalPodAutoscaler` (HPA) based on custom Traefik metrics (request-per-second) rather than just CPU/RAM.
