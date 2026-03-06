#!/bin/bash
set -e

NAMESPACE="foobar-namespace"
DOMAIN="foobar.local"

# 1. Ensure Namespace and PVC exist
kubectl apply -f k8s/base/namespace.yaml
kubectl apply -f k8s/base/pvc.yaml

# 2. Generate certs locally
openssl req -x509 -newkey rsa:4096 -keyout tls.key -out tls.crt -days 365 -nodes -subj "/CN=$DOMAIN"

# 3. Use a temporary pod to copy files into the PVC
# This is the "Architect" way to handle PVC population without manual SSH
kubectl run pvc-helper --image=alpine -n $NAMESPACE --overrides='
{
  "spec": {
    "containers": [{
      "name": "pvc-helper",
      "image": "alpine",
      "command": ["sh", "-c", "sleep 3600"],
      "volumeMounts": [{"name": "data", "mountPath": "/certs"}]
    }],
    "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "traefik-certs-pvc"}}]
  }
}'

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod/pvc-helper -n $NAMESPACE --timeout=30s

# Copy files and cleanup
kubectl cp tls.crt $NAMESPACE/pvc-helper:/certs/tls.crt
kubectl cp tls.key $NAMESPACE/pvc-helper:/certs/tls.key
kubectl delete pod pvc-helper -n $NAMESPACE

rm tls.crt tls.key
echo "Successfully populated PVC with certificates."
