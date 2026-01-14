Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Assert-LastExitCode([string]$What) {
    if ($LASTEXITCODE -ne 0) {
        Fail "$What failed with exit code $LASTEXITCODE."
    }
}

$namespace = 'defectdojo'
$releaseName = 'defectdojo'
$repoName = 'defectdojo'
$repoUrl = 'https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts'
$chartRef = 'defectdojo/defectdojo'
$chartVersion = if ([string]::IsNullOrWhiteSpace($env:DD_CHART_VERSION)) { '1.9.5' } else { $env:DD_CHART_VERSION }

if ([string]::IsNullOrWhiteSpace($env:DD_HOST)) { Fail 'Missing required env var: DD_HOST' }

Write-Host "Ensuring namespace '$namespace' exists..."
$ns = kubectl get ns $namespace -o name 2>$null
if (-not $ns) {
    kubectl create ns $namespace | Out-Host
    Assert-LastExitCode "kubectl create ns $namespace"
}

Write-Host "Adding Helm repo '$repoName'..."
helm repo add $repoName $repoUrl --force-update | Out-Host
Assert-LastExitCode 'helm repo add'
helm repo update | Out-Host
Assert-LastExitCode 'helm repo update'

# The chart recommends creating certain secrets only on first install.
# We make the install/upgrade idempotent by detecting whether secrets already exist.
function SecretExists([string]$name) {
    $null = kubectl get secret $name -n $namespace 2>$null
    return $LASTEXITCODE -eq 0
}

$createSecret = -not (SecretExists 'defectdojo')
$createValkeySecret = -not (SecretExists 'defectdojo-valkey-specific')
$createPostgresqlSecret = -not (SecretExists 'defectdojo-postgresql-specific')

Write-Host "Idempotency flags: createSecret=$createSecret createValkeySecret=$createValkeySecret createPostgresqlSecret=$createPostgresqlSecret"

# Must include: helm upgrade --install defectdojo <chart> --namespace defectdojo -f k8s/defectdojo-values.yaml
Write-Host "Installing/upgrading '$releaseName' from '$chartRef' (version $chartVersion)..."
helm upgrade --install $releaseName $chartRef --version $chartVersion --namespace $namespace -f k8s/defectdojo-values.yaml `
  --set host=$env:DD_HOST `
  --set siteUrl=("http://" + $env:DD_HOST) `
  --set django.ingress.ingressClassName=nginx `
  --set django.ingress.activateTLS=false `
  --set createSecret=$createSecret `
  --set createValkeySecret=$createValkeySecret `
  --set createPostgresqlSecret=$createPostgresqlSecret | Out-Host
Assert-LastExitCode 'helm upgrade --install'

Write-Host 'Waiting for deployments to become ready (rollout status)...'
$deployments = kubectl get deploy -n $namespace -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
Assert-LastExitCode "kubectl get deploy -n $namespace"

$deploymentList = @(
    $deployments -split "`n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

if ($deploymentList.Count -eq 0) {
    Fail "No deployments found in namespace '$namespace' after Helm install."
}

foreach ($deployment in $deploymentList) {
    Write-Host "- kubectl rollout status deployment/$deployment"
    kubectl rollout status deployment/$deployment -n $namespace --timeout=10m | Out-Host
    Assert-LastExitCode "kubectl rollout status deployment/$deployment"
}
