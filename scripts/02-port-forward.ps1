# scripts/02-port-forward.ps1
#
# Starts three background port-forwards:
#   - ArgoCD UI:   https://localhost:8443  (admin / see bootstrap output)
#   - LiteLLM:     http://localhost:4000   (master key: sk-litellm-local-dev-key)
#   - LiteLLM UI:  http://localhost:4000/ui
#
# Ctrl-C this window to stop all three.

$ErrorActionPreference = "Stop"

Write-Host "==> Waiting for ArgoCD server to be ready..." -ForegroundColor Cyan
kubectl -n argocd wait --for=condition=available --timeout=300s deployment/argocd-server

Write-Host "==> Waiting for LiteLLM to be ready (this may take a few minutes on first install)..." -ForegroundColor Cyan
# LiteLLM may not exist yet if ArgoCD hasn't synced — retry for 5 min
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    $exists = kubectl -n litellm get deployment 2>$null | Select-String "litellm"
    if ($exists) { break }
    Start-Sleep -Seconds 10
}
kubectl -n litellm wait --for=condition=available --timeout=600s deployment -l app.kubernetes.io/name=litellm

Write-Host ""
Write-Host "==> Starting port-forwards (Ctrl-C to stop all)..." -ForegroundColor Green
Write-Host "    ArgoCD:  http://localhost:8080"
Write-Host "    LiteLLM: http://localhost:4000  (master key: sk-litellm-local-dev-key)"
Write-Host ""

# Start port-forwards as background jobs
$argoJob = Start-Job -Name argocd-pf -ScriptBlock {
    kubectl -n argocd port-forward svc/argocd-server 8080:80
}
$llmJob = Start-Job -Name litellm-pf -ScriptBlock {
    # Service name follows <release>-litellm pattern from the Helm chart
    kubectl -n litellm port-forward svc/litellm 4000:4000
}

try {
    Write-Host "Port-forwards running. Press Ctrl-C to stop."
    while ($true) {
        Start-Sleep -Seconds 5
        # Surface any job errors
        Get-Job | Where-Object { $_.State -eq "Failed" } | ForEach-Object {
            Write-Warning "Job $($_.Name) failed:"
            Receive-Job $_
        }
    }
} finally {
    Write-Host "`nStopping port-forwards..." -ForegroundColor Yellow
    Get-Job | Stop-Job -PassThru | Remove-Job -Force
}
