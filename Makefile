# the history/docs for the encapsulated in code
# variables
NAMESPACE=foobar-namespace
IMAGE_NAME=foobar-api:latest

.PHONY: all check-tools build-image setup-infra deploy-app clean help

all: check-tools build-image setup-infra deploy-app ## Full build and deploy sequence 

check-tools: ## Ensure required binaries are installed
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
	kubectl apply -f k8s/traefik/traefik-deployment.yaml
	# create the ConfigMap from the local file instead of applying the file itself
	kubectl create configmap traefik-dynamic-config \
		--from-file=dynamic.yaml=k8s/traefik/dynamic-conf.yaml \
		-n $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/traefik/traefik-config.yaml

deploy-app: ## deploy the API and network policies
	@echo "--- Deploying Application ---"
	kubectl apply -f k8s/base/deployment.yaml 
	kubectl apply -f k8s/base/service.yaml 
	kubectl apply -f k8s/base/network-policy.yaml 

clean: ## remove the entire stack
	@echo "--- Cleaning up ---"
	kubectl delete namespace $(NAMESPACE) 

help: ## Show a help menu 
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'