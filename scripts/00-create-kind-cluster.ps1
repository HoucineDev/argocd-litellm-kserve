# scripts/00-create-kind-cluster.ps1
# Creates the kind cluster. Assumes Docker Desktop is running with WSL2 backend.

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "==> Checking prerequisites..." -ForegroundColor Cyan

# Docker
try { docker info *>$null } catch {
    Write-Error "Docker is not running. Start Docker Desktop first."
}

# kind
if (-not (Get-Command kind -ErrorAction SilentlyContinue)) {
    Write-Error "kind not found. Install: winget install Kubernetes.kind"
}

# kubectl
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Error "kubectl not found. Install: winget install Kubernetes.kubectl"
}

# helm
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    Write-Error "helm not found. Install: winget install Helm.Helm"
}

Write-Host "==> Creating kind cluster 'llm-platform'..." -ForegroundColor Cyan

$existing = kind get clusters 2>$null
if ($existing -contains "llm-platform") {
    Write-Host "Cluster already exists. Delete with: kind delete cluster --name llm-platform" -ForegroundColor Yellow
    exit 0
}

kind create cluster --config "$ScriptDir\kind-config.yaml"

Write-Host "==> Waiting for node to be Ready..." -ForegroundColor Cyan
kubectl wait --for=condition=Ready node --all --timeout=120s

Write-Host "==> Cluster info:" -ForegroundColor Cyan
kubectl cluster-info --context kind-llm-platform
kubectl get nodes -o wide

Write-Host ""
Write-Host "Cluster ready. Next: bash scripts/01-bootstrap.sh" -ForegroundColor Green
