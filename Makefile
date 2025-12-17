.PHONY: all build rust elixir test docker deploy clean

# Variables
IMAGE_NAME ?= nopea
IMAGE_TAG ?= latest
NAMESPACE ?= nopea-system

all: build

# Build everything
build: rust elixir

# Build Rust binary
rust:
	@echo "Building Rust binary..."
	cd nopea-git && cargo build --release
	@echo "Rust binary built: nopea-git/target/release/nopea-git"

# Build Elixir
elixir:
	@echo "Building Elixir..."
	mix deps.get
	mix compile
	@echo "Elixir compiled"

# Run Rust tests
test-rust:
	@echo "Running Rust tests..."
	cd nopea-git && cargo test

# Run Elixir tests
test-elixir:
	@echo "Running Elixir tests..."
	mix test

# Run all tests
test: test-rust test-elixir

# Build Docker image
docker:
	@echo "Building Docker image $(IMAGE_NAME):$(IMAGE_TAG)..."
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .
	@echo "Docker image built"

# Load image to kind cluster
kind-load: docker
	@echo "Loading image to kind cluster..."
	kind load docker-image $(IMAGE_NAME):$(IMAGE_TAG)
	@echo "Image loaded to kind"

# Deploy CRD
deploy-crd:
	@echo "Deploying CRD..."
	kubectl apply -f deploy/crd.yaml

# Deploy RBAC
deploy-rbac:
	@echo "Deploying RBAC..."
	kubectl apply -f deploy/rbac.yaml

# Deploy controller
deploy-controller:
	@echo "Deploying controller..."
	kubectl apply -f deploy/deployment.yaml

# Full deployment
deploy: deploy-crd deploy-rbac deploy-controller
	@echo "Deployment complete"

# Undeploy everything
undeploy:
	@echo "Removing deployment..."
	-kubectl delete -f deploy/deployment.yaml
	-kubectl delete -f deploy/rbac.yaml
	-kubectl delete -f deploy/crd.yaml
	@echo "Deployment removed"

# Run locally (development)
run:
	@echo "Starting NOPEA locally..."
	iex -S mix

# Run with controller disabled (for testing)
run-no-controller:
	@echo "Starting NOPEA without controller..."
	NOPEA_ENABLE_CONTROLLER=false iex -S mix

# Format code
fmt:
	cd nopea-git && cargo fmt
	mix format

# Lint
lint:
	cd nopea-git && cargo clippy -- -D warnings
	mix credo --strict || true

# Clean build artifacts
clean:
	@echo "Cleaning..."
	cd nopea-git && cargo clean
	rm -rf _build deps
	@echo "Cleaned"

# Create kind cluster
kind-create:
	@echo "Creating kind cluster..."
	kind create cluster --name nopea

# Delete kind cluster
kind-delete:
	@echo "Deleting kind cluster..."
	kind delete cluster --name nopea

# Full development setup
dev-setup: kind-create kind-load deploy

# Show logs
logs:
	kubectl logs -n $(NAMESPACE) -l app=nopea-controller -f

# Get status
status:
	@echo "=== Pods ==="
	kubectl get pods -n $(NAMESPACE)
	@echo ""
	@echo "=== GitRepositories ==="
	kubectl get gitrepositories -A

# Help
help:
	@echo "NOPEA Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  build          - Build Rust and Elixir"
	@echo "  rust           - Build Rust binary only"
	@echo "  elixir         - Build Elixir only"
	@echo "  test           - Run all tests"
	@echo "  test-rust      - Run Rust tests"
	@echo "  test-elixir    - Run Elixir tests"
	@echo "  docker         - Build Docker image"
	@echo "  kind-load      - Build and load image to kind"
	@echo "  deploy         - Deploy to Kubernetes"
	@echo "  undeploy       - Remove from Kubernetes"
	@echo "  run            - Run locally"
	@echo "  fmt            - Format code"
	@echo "  lint           - Lint code"
	@echo "  clean          - Clean build artifacts"
	@echo "  dev-setup      - Full development setup (kind + deploy)"
	@echo "  logs           - Show controller logs"
	@echo "  status         - Show deployment status"
