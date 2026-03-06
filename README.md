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

1.1. **Check Traefik pod status**
Ensure the Traefik pod is running. Because of the added `initContainer`, it won't even start unless the certificates are physically present in the volume.
```bash
kubectl get pods -n foobar-namespace -l app=traefik

```

1.2. **Check the API pod status**
```bash
kubectl get pods -n foobar-namespace -l app=foobar-api

```

* If they show `0/1 READY`, run 
```bash
kubectl describe pod -n foobar-namespace -l app=foobar-api

```
* Check if the Go application is actually listening on `/` or if it requires a different health check path (like `/health`).

1.3. **Inspect the logs for TLS loading**
Confirm if Traefik successfully parsed your dynamic.yaml and found the certificates:
```bash
kubectl logs -n foobar-namespace -l app=traefik -c traefik | grep -i "TLS"

```

*What you want to see: 
* A message stating that the "Configuration loaded from file: /config/dynamic.yaml"
* No errors regarding missing files at `/certs/tls.crt` or `/certs/tls.key`

1.4. **Check if certs are actually there - odd things can happen**
```bash
kubectl run pvc-check --image=alpine -n foobar-namespace --restart=Never --rm -it --overrides='{"spec": {"volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "traefik-certs-pvc"}}], "containers": [{"name": "check", "image": "alpine", "command": ["ls", "-l", "/certs"], "volumeMounts": [{"name": "data", "mountPath": "/certs"}]}]}}'

```


If you see `tls.crt` and `tls.key` in the output, your mission is accomplished. You should see something like:
```text
total 8
-rw-r--r--    1 root     root          1675 Mar  6 14:24 tls.crt
-rw-r--r--    1 root     root          1704 Mar  6 14:24 tls.key
pod "pvc-check" deleted

```

1.5. **Confirm the ConfigMap Content**
```bash
kubectl get configmap traefik-dynamic-config -n foobar-namespace -o yaml

```

You should see something like:
```text
apiVersion: v1
data:
  dynamic.yaml: |
    tls:
      certificates:
        - certFile: /certs/tls.crt
          keyFile: /certs/tls.key
kind: ConfigMap
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"v1","data":{"dynamic.yaml":"tls:\n  certificates:\n    - certFile: /certs/tls.crt\n      keyFile: /certs/tls.key\n"},"kind":"ConfigMap","metadata":{"annotations":{},"name":"traefik-dynamic-config","namespace":"foobar-namespace"}}
  creationTimestamp: "2026-03-06T17:38:09Z"
  name: traefik-dynamic-config
  namespace: foobar-namespace
  resourceVersion: "6739"
  uid: 1b30560c-1120-4de7-9d27-1fdd51211865

```

1.6. **Check Traefik's Internal Pulse**
```bash
kubectl logs -n foobar-namespace -l app=traefik | grep -i "Configuration loaded"

```

You want to see Traefik acknowledging that the file provider has successfully loaded the configuration from `/config/dynamic.yaml`

2. **Verification:**
From your local machine, perform a curl to simulate an external request. This confirms that the Traefik ingress is correctly using the PVC certs to terminate the SSL connection:
```bash
curl -vI -k https://foobar.local --resolve foobar.local:443:127.0.0.1

```

* -vI: shows the verbose header info (including the certificate CN)
* -k: allows the self-signed certificate you generated in your script
* --resolve: maps the domain to your local IP without needing to edit `/etc/hosts` immediately (but, don't forget about it)

* You should now see subject: CN=foobar.local and a 200 OK (or similar success code).

If you reached this point, it's all deployed, and the API is accessible via HTTPS. You can verify the secure connection using:
```bash
curl -k https://foobar.local --resolve foobar.local:443:127.0.0.1

```

3. **Cleanup:**
To tear down the environment, simply run:
```bash
make clean

```

---

## Future Considerations

* **Key Management:** Transition from PVC-stored certificates to a native **KMS/Vault** integration using `External Secrets Operator`.
* **Autoscaling:** Implement a `HorizontalPodAutoscaler` (HPA) based on custom Traefik metrics (request-per-second) rather than just CPU/RAM.
