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
$helmArgs = @(
        'upgrade', '--install',
        $releaseName,
        $chartRef,
        '--version', $chartVersion,
        '--namespace', $namespace,
        '-f', 'k8s/defectdojo-values.yaml',
        '--set', "host=$($env:DD_HOST)",
        '--set', ("siteUrl=http://" + $env:DD_HOST),
        '--set', 'django.ingress.ingressClassName=nginx',
        '--set', 'django.ingress.activateTLS=false',
        '--set', ("createSecret=$createSecret"),
        '--set', ("createValkeySecret=$createValkeySecret"),
        '--set', ("createPostgresqlSecret=$createPostgresqlSecret")
)

Write-Host ('Running: helm ' + ($helmArgs -join ' '))
& helm @helmArgs | Out-Host
Assert-LastExitCode 'helm upgrade --install'

Write-Host 'Waiting for DefectDojo initializer job (migrations/bootstrap)...'
$initializerSelector = 'defectdojo.org/component=initializer'

$sawJob = $false
$start = Get-Date
$timeoutAt = $start.AddMinutes(20)
$lastStatusLine = ''

while ((Get-Date) -lt $timeoutAt) {
    $jobJson = kubectl get job -n $namespace -l $initializerSelector -o json 2>$null
    if ($LASTEXITCODE -ne 0) {
        Fail 'kubectl get job for initializer selector failed.'
    }

    $jobs = $null
    try {
        $jobs = $jobJson | ConvertFrom-Json
    } catch {
        Fail "Failed to parse initializer job JSON: $($_.Exception.Message)"
    }

    $items = @($jobs.items)
    if ($items.Count -eq 0) {
        if ($sawJob) {
            Write-Host 'Initializer job disappeared before completing. Showing recent events for debugging:'
            kubectl get events -n $namespace --sort-by=.lastTimestamp | Select-Object -Last 40 | Out-Host
            Fail 'Initializer job disappeared before completing (possibly deleted after failure).'
        }

        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        if ($elapsed -eq 0 -or ($elapsed % 30 -eq 0)) {
            Write-Host 'Initializer job not created yet; waiting...'
        }
        Start-Sleep -Seconds 5
        continue
    }

    $sawJob = $true
    $job = $items | Sort-Object { $_.metadata.creationTimestamp } | Select-Object -Last 1
    $name = $job.metadata.name

    $active = 0
    $succeeded = 0
    $failed = 0

    if ($job.PSObject.Properties.Match('status').Count -gt 0 -and $job.status) {
        if ($job.status.PSObject.Properties.Match('active').Count -gt 0 -and $job.status.active) { $active = [int]$job.status.active }
        if ($job.status.PSObject.Properties.Match('succeeded').Count -gt 0 -and $job.status.succeeded) { $succeeded = [int]$job.status.succeeded }
        if ($job.status.PSObject.Properties.Match('failed').Count -gt 0 -and $job.status.failed) { $failed = [int]$job.status.failed }
    }

    $statusLine = "initializer job=$name active=$active succeeded=$succeeded failed=$failed"
    if ($statusLine -ne $lastStatusLine) {
        Write-Host $statusLine
        $lastStatusLine = $statusLine
    } elseif (((Get-Date) - $start).TotalSeconds % 30 -lt 6) {
        Write-Host $statusLine
    }

    if ($succeeded -ge 1) {
        Write-Host 'Initializer job completed.'
        break
    }

    if ($failed -ge 1) {
        Write-Host 'Initializer job failed. Capturing diagnostics...'
        kubectl describe job -n $namespace $name | Out-Host
        kubectl logs -n $namespace job/$name --all-containers --tail=200 | Out-Host
        Fail 'Initializer job failed.'
    }

    Start-Sleep -Seconds 10
}

if ((Get-Date) -ge $timeoutAt) {
    Write-Host 'Initializer job did not complete within 20 minutes. Recent events:'
    kubectl get events -n $namespace --sort-by=.lastTimestamp | Select-Object -Last 40 | Out-Host
    Fail 'Initializer job timed out.'
}

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
    kubectl rollout status deployment/$deployment -n $namespace --timeout=20m | Out-Host
    Assert-LastExitCode "kubectl rollout status deployment/$deployment"
}
