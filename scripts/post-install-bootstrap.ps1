Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Warn([string]$Message) { Write-Warning $Message }
function Fail([string]$Message) { Write-Error $Message; exit 1 }

if ([string]::IsNullOrWhiteSpace($env:DD_HOST)) { Fail 'Missing required env var: DD_HOST' }

$namespace = 'defectdojo'
$url = "http://$($env:DD_HOST)"

Write-Host "DefectDojo URL (from DD_HOST): $url"

Write-Host 'Discovering ingress status (if present)...'
$ingJson = kubectl get ingress -n $namespace -o json 2>$null
if ($LASTEXITCODE -eq 0 -and $ingJson) {
    try {
        $ing = $ingJson | ConvertFrom-Json
        if ($ing.items.Count -gt 0) {
            $first = $ing.items[0]
            $ingName = $first.metadata.name
            $addr = $first.status.loadBalancer.ingress[0]
            $addrText = if ($addr.ip) { $addr.ip } elseif ($addr.hostname) { $addr.hostname } else { '' }
            Write-Host "Ingress detected: $ingName" 
            if ($addrText) { Write-Host "Ingress address: $addrText" }
        }
    } catch {
        Warn "Could not parse ingress JSON: $($_.Exception.Message)"
    }
}

Write-Host 'Checking whether the UI is reachable (best-effort)...'
try {
    $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 15 -UseBasicParsing
    Write-Host "UI HTTP status: $($resp.StatusCode)"
} catch {
    Warn "UI check failed from agent (DNS/LB may not be ready): $($_.Exception.Message)"
}

# Attempt API token bootstrap using the admin password from the chart-managed secret.
# If this fails (e.g., host not reachable from agent), we fall back to manual instructions.
Write-Host 'Attempting to obtain admin password from Kubernetes secret defectdojo...'
$adminPassword = $null
try {
    $b64 = kubectl get secret defectdojo -n $namespace -o jsonpath='{.data.DD_ADMIN_PASSWORD}' 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($b64)) {
        $adminPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
    }
} catch {
    Warn "Could not read admin password: $($_.Exception.Message)"
}

if (-not $adminPassword) {
    Warn "Admin password not available (or secret missing). Create an API token manually in the UI: $url -> User menu -> API v2 Key."
    Write-Host '##vso[task.setvariable variable=DD_API_TOKEN;isOutput=true]'
    exit 0
}

Write-Host 'Attempting to request an API token via /api/v2/api-token-auth/...'
try {
    $tokenResponse = Invoke-RestMethod -Method Post -Uri ("$url/api/v2/api-token-auth/") -ContentType 'application/json' -Body (ConvertTo-Json @{ username = 'admin'; password = $adminPassword }) -TimeoutSec 20
    $token = $tokenResponse.token
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Token response did not contain 'token'."
    }

    Write-Host 'Successfully obtained DefectDojo API token (stored as pipeline output variable DD_API_TOKEN).'
    Write-Host "##vso[task.setvariable variable=DD_API_TOKEN;isOutput=true]$token"
} catch {
    Warn "Automatic API token bootstrap failed: $($_.Exception.Message)"
    Warn "Create an API token manually in the UI: $url -> User menu -> API v2 Key. Then store it as a secret variable/group named DD_API_TOKEN for downstream pipelines."
    Write-Host '##vso[task.setvariable variable=DD_API_TOKEN;isOutput=true]'
}
