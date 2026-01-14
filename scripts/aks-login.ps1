Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

if ([string]::IsNullOrWhiteSpace($env:AKS_RG)) { Fail 'Missing required env var: AKS_RG' }
if ([string]::IsNullOrWhiteSpace($env:AKS_NAME)) { Fail 'Missing required env var: AKS_NAME' }

Write-Host "Logging into AKS cluster '$($env:AKS_NAME)' in RG '$($env:AKS_RG)' (admin kubeconfig)..."
az aks get-credentials --admin --overwrite-existing --resource-group $env:AKS_RG --name $env:AKS_NAME

Write-Host 'Verifying kubectl access...'
# Client version check
kubectl version --client=true
# Cluster access check
kubectl get ns
