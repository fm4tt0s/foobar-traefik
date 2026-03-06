#!/usr/bin/env bash
#
# author    : felipe mattos
# email     : fmattos
# date      : March-6-2026
# version   : 0.2
#
# purpose   : automation script for Day-0 certificate lifecycle and programmatic PVC data population.
# remarks   : optimized for late-binding storage provisioners (e.g., Rancher Desktop)
# require   : kubectl, openssl, and a Kubernetes cluster.
#
_deps=("kubectl" "openssl")

# runtime globals / variable initialization
_this="$(basename "${BASH_SOURCE[0]}")"
_this_path="$( cd "$(dirname "${BASH_SOURCE[0]}")" || return 0 ; pwd -P )"

# base vars
_NAMESPACE="foobar-namespace"
_DOMAIN="foobar.local"

# functions
function tellmom() {
    # what: yell to mamma - if param2 is given (exit code), script will bail with given code
    echo "$(date '+%D %T')|${_this}|${1}" 
    [[ -n "${2}" ]] && exit "${2}"
}

# first things first
[[ -z "${BASH}" || "${BASH_VERSINFO[0]}" -lt 3 ]] && tellmom "ERROR|bash 3+ required" 1

function zitheer() {
    # what: check if whatever dependency is satisfied
    local _cmd && _cmd=$(command -v "${1}")
    [[ -n "${_cmd}" ]] && [[ -f "${_cmd}" ]]
    return "${?}"
}

# main
for _dep in "${_deps[@]}"; do zitheer "${_dep}" || tellmom "${_dep} required" 1; done

# ensure namespace and PVC exist
tellmom "applying infrastructure manifests..."
kubectl apply -f k8s/base/namespace.yaml
kubectl apply -f k8s/base/pvc.yaml

# generate certs locally
tellmom "generating certificates..."
openssl req -x509 -newkey rsa:4096 -keyout tls.key -out tls.crt -days 365 -nodes -subj "/CN=${_DOMAIN}"

# use a temporary pod to copy files into the PVC
# Note: We trigger the pod IMMEDIATELY to satisfy the "WaitForFirstConsumer" policy
tellmom "starting helper pod to trigger volume binding..."
kubectl run pvc-helper --image=alpine:latest -n "${_NAMESPACE}" --restart=Never --overrides='
{
  "spec": {
    "containers": [{
      "name": "pvc-helper",
      "image": "alpine:latest",
      "command": ["sh", "-c", "sleep 3600"],
      "volumeMounts": [{"name": "data", "mountPath": "/certs"}]
    }],
    "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "traefik-certs-pvc"}}]
  }
}'

# wait for pod with an increased timeout (90s)
tellmom "waiting for helper pod to reach Ready state (binding storage)..."
kubectl wait --for=condition=Ready pod/pvc-helper -n "${_NAMESPACE}" --timeout=90s || {
    tellmom "Pod failed to reach Ready state. Checking PVC status..."
    kubectl get pvc -n "${_NAMESPACE}"
    kubectl describe pod pvc-helper -n "${_NAMESPACE}"
    exit 1
}

# 5. Copy files and cleanup
tellmom "copying certificates to PVC..."
kubectl cp tls.crt "${_NAMESPACE}"/pvc-helper:/certs/tls.crt
kubectl cp tls.key "${_NAMESPACE}"/pvc-helper:/certs/tls.key

tellmom "cleaning up temporary pod..."
# remove --force to avoid the warning that trips up some shells
kubectl delete pod pvc-helper -n "${_NAMESPACE}" --grace-period=0 --force

# clean up local files
rm -rf tls.crt tls.key
tellmom "successfully populated PVC with certificates."
# explicitly return success to the Makefile - this gets wild some times
exit 0 