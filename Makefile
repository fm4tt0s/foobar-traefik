# full lifecycle automation
# variables
NAMESPACE=foobar-namespace
IMAGE_NAME=foobar-api:latest

.PHONY: all check-tools build-image setup-infra deploy-app clean help

all: check-tools build-image setup-infra deploy-app ## full build and deploy sequence 

check-tools: ## ensure required binaries are installed
	@echo "--- Checking prerequisites ---"
	@command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required"; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo "docker is required"; exit 1; }
	@command -v openssl >/dev/null 2>&1 || { echo "openssl is required"; exit 1; }

build-image: ## Build the Docker image locally
	@echo "--- Building Docker image ---"
	docker build -t $(IMAGE_NAME) . 

setup-infra: ## prepare namespace, RBAC, certs, and Traefik
	@echo "--- Setting up Infrastructure ---"
	kubectl apply -f k8s/base/namespace.yaml
	chmod +x scripts/generate-certs.sh
	./scripts/generate-certs.sh
	kubectl apply -f k8s/traefik/rbac.yaml
	kubectl apply -f k8s/base/pvc.yaml
	[ -f k8s/traefik/crds.yaml ] || curl -o k8s/traefik/crds.yaml https://raw.githubusercontent.com/traefik/traefik/v3.0.0/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
	kubectl apply -f k8s/traefik/crds.yaml
	kubectl apply -f k8s/traefik/traefik-deployment.yaml
	kubectl create configmap traefik-dynamic-config \
		--from-file=dynamic.yaml=k8s/traefik/dynamic-conf.yaml \
		-n $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/traefik/traefik-service.yaml
	kubectl apply -f k8s/traefik/serverstransport.yaml
# Wait for Traefik to be fully ready before applying IngressRoute
	kubectl rollout status deployment/traefik -n $(NAMESPACE) --timeout=120s
	kubectl apply -f k8s/traefik/ingressroute.yaml
	grep -q "foobar.local" /etc/hosts \
		&& echo "--- foobar.local is already in /etc/hosts ---" \
		|| echo "--- Please add foobar.local to your /etc/hosts file pointing to your cluster's IP ---"

deploy-app: ## deploy the API and network policies
	@echo "--- Deploying Application ---"
	kubectl apply -f k8s/base/deployment.yaml 
	kubectl apply -f k8s/base/service.yaml 
	kubectl apply -f k8s/base/network-policy.yaml 

test: ## run basic tests against the deployed API
# this is encapsulated in a bash command as it involves multiple steps and checks, and we want to ensure it runs with strict error handling - besides, I didnt have enough time to deal with SH shenenigans nor to write a proper test suite with a framework, so this is a quick way to validate the endpoints
	@bash -euo pipefail -c '\
	echo "--- Waiting for API to be ready ---"; \
	kubectl rollout status deployment/foobar-api -n $(NAMESPACE) --timeout=60s; \
	echo "--- Running Tests ---"; \
	\
	echo "--- Waiting for Traefik to sync endpoints ---"; \
	for i in $$(seq 1 10); do \
		_status=$$(curl -sk -o /dev/null -w "%{http_code}" https://foobar.local/health); \
		[[ "$${_status}" == "200" ]] && break; \
		echo "waiting for traffic... attempt $${i}/10"; \
		sleep 3; \
	done; \
	echo "# api"; \
	_api=$$(curl -sk https://foobar.local/api | tr "," "\n" | grep -cE "X-Forwarded-For|X-Forwarded-Proto.*https|X-Forwarded-Server.*traefik"); \
	[[ "$${_api}" -ge 3 ]] \
		&& echo "--- API test endpoint is working ---" \
		|| echo "--- API test endpoint failed ---"; \
	\
	echo "# data (body size)"; \
	_data=$$(curl -sk "https://foobar.local/data?size=32&unit=kb"); \
	LC_ALL=C _sizebytes="$${#_data}"; \
	[[ "$${_sizebytes}" -ge 32000 ]] \
		&& echo "--- Data test endpoint is working ---" \
		|| echo "--- Data test endpoint failed (got $${_sizebytes} bytes) ---"; \
	\
	echo "# data (attachment download)"; \
	rm -f ./data; \
	curl -sk -O "https://foobar.local/data?size=32&unit=kb&attachment=true"; \
	[[ -f ./data ]] \
		&& echo "--- Data test endpoint with attachment is working ---" \
		|| echo "--- Data test endpoint with attachment failed ---"; \
	_size=$$(wc -c < data); \
	[[ "$${_size}" -gt 32000 ]] \
		&& echo "--- Data test endpoint with attachment is correct size ---" \
		|| echo "--- Data test endpoint with attachment is incorrect size ---"; \
	\
	rm -f ./data; \
	echo "# health"; \
	_health=$$(curl -k -I https://foobar.local/health 2>&1 | grep -cE "^HTTP.*200"); \
	[[ "$${_health}" -eq 1 ]] \
		&& echo "--- Health endpoint is healthy ---" \
		|| echo "--- Health endpoint is unhealthy ---"; \
	\
	echo "# websocket (echo)"; \
	if command -v wscat >/dev/null 2>&1; then \
		wscat -nc wss://foobar.local/echo --execute echo \
			&& echo "--- WebSocket endpoint is working ---" \
			|| echo "--- WebSocket endpoint failed ---"; \
	else \
		echo "--- wscat is not installed, skipping WebSocket test ---"; \
	fi \
	'

clean: ## remove the entire stack
	@echo "--- Cleaning up ---"
	kubectl delete namespace $(NAMESPACE)

help: ## Show a help menu 
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'