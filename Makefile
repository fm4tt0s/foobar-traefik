# the history/docs for the encapsulated in code
# Variables
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

setup-infra: ## Prepare Namespace, RBAC, Certs, and Traefik
	@echo "--- Setting up Infrastructure ---"
	kubectl apply -f k8s/base/namespace.yaml 
	# Make script executable and run it
	chmod +x scripts/generate-certs.sh
	./scripts/generate-certs.sh
	kubectl apply -f k8s/traefik/rbac.yaml 
	kubectl apply -f k8s/base/pvc.yaml 
	# Apply Traefik Infrastructure
	kubectl apply -f k8s/traefik/traefik-deployment.yaml 
	# Deploy Dynamic Config as a ConfigMap if it's not already defined in YAML
	kubectl apply -f k8s/traefik/traefik-config.yaml 
	kubectl apply -f k8s/traefik/dynamic-conf.yaml 

deploy-app: ## Deploy the API and Network Policies
	@echo "--- Deploying Application ---"
	kubectl apply -f k8s/base/deployment.yaml 
	kubectl apply -f k8s/base/service.yaml 
	kubectl apply -f k8s/base/network-policy.yaml 

clean: ## Remove the entire stack
	@echo "--- Cleaning up ---"
	kubectl delete namespace $(NAMESPACE) 

help: ## Show this help menu 
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' [cite: 7]