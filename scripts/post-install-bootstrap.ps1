Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Warn([string]$Message) { Write-Warning $Message }
function Fail([string]$Message) { Write-Error $Message; exit 1 }

$namespace = 'defectdojo'

if ([string]::IsNullOrWhiteSpace($env:DD_HOST)) { Fail 'Missing required env var: DD_HOST' }
$scheme = if ([string]::IsNullOrWhiteSpace($env:DD_SCHEME)) { 'http' } else { $env:DD_SCHEME }
$url = "${scheme}://$($env:DD_HOST)"

function Assert-LastExitCode([string]$What) {
    if ($LASTEXITCODE -ne 0) {
        Fail "$What failed with exit code $LASTEXITCODE."
    }
}

function Try-ResolveHost([string]$Host) {
    try {
        return [System.Net.Dns]::GetHostAddresses($Host)
    } catch {
        return $null
    }
}

function Test-TcpConnect([string]$Host, [int]$Port, [int]$TimeoutMs = 3000) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($Host, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            try { $client.Close() } catch {}
            return $false
        }
        $client.EndConnect($async)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

Write-Host 'Waiting for DefectDojo initializer job to complete (up to 20 minutes)...'
kubectl -n $namespace get jobs | Out-Host
Assert-LastExitCode 'kubectl get jobs'

$waitSelector = 'app.kubernetes.io/instance=defectdojo'
kubectl -n $namespace wait --for=condition=complete job -l $waitSelector --timeout=20m | Out-Host
if ($LASTEXITCODE -ne 0) {
    Warn 'Initializer job did not complete successfully. Capturing diagnostics...'
    try {
        kubectl -n $namespace describe job -l $waitSelector | Out-Host
    } catch {
        Warn "Failed to describe jobs: $($_.Exception.Message)"
    }

    try {
        $jobName = kubectl -n $namespace get job -l 'defectdojo.org/component=initializer' -o jsonpath='{.items[0].metadata.name}' 2>$null
        $jobName = ($jobName | Out-String).Trim()
        if (-not $jobName) {
            $jobName = kubectl -n $namespace get job -l $waitSelector -o jsonpath='{.items[0].metadata.name}' 2>$null
            $jobName = ($jobName | Out-String).Trim()
        }
        if ($jobName) {
            kubectl -n $namespace logs job/$jobName --all-containers --tail=200 | Out-Host
        } else {
            Warn 'Could not determine initializer job name for logs.'
        }
    } catch {
        Warn "Failed to get initializer logs: $($_.Exception.Message)"
    }

    Fail 'Initializer job failed or timed out.'
}

Write-Host "DefectDojo URL (from DD_HOST): $url"

Write-Host 'Determining ingress controller external address (ingress-nginx)...'
$lbIp = (kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null | Out-String).Trim()
if (-not $lbIp) {
    $lbIp = (kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null | Out-String).Trim()
}

if ($lbIp) {
    $parsedIp = $null
    $isIp = [System.Net.IPAddress]::TryParse($lbIp, [ref]$parsedIp)

    if ($isIp) {
        $suggestedHost = "defectdojo.$lbIp.nip.io"
        Write-Host "##vso[task.setvariable variable=DD_SUGGESTED_HOST]$suggestedHost"
        Write-Host "Open: http://$suggestedHost/login"
    } else {
        Warn "Ingress external address is a hostname ('$lbIp'); nip.io suggestion skipped."
        Write-Host "Ingress address: $lbIp"
    }
} else {
    Warn 'Ingress has no external IP/hostname (pending or internal load balancer).'
}

Write-Host 'Reading admin password from Kubernetes secret (without printing it)...'
try {
    $b64 = (kubectl -n $namespace get secret defectdojo -o jsonpath='{.data.DD_ADMIN_PASSWORD}' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($b64)) {
        $adminPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
        Write-Host "##vso[task.setvariable variable=DD_ADMIN_PASSWORD_FROM_CLUSTER;issecret=true]$adminPassword"
    } else {
        Warn 'Admin password secret value not found (secret may not exist yet).'
    }
} catch {
    Warn "Could not read admin password: $($_.Exception.Message)"
}

Write-Host 'Discovering ingress status (if present)...'
try {
    $ingJson = kubectl get ingress -n $namespace -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $ingJson) {
        $ing = $ingJson | ConvertFrom-Json
        if ($ing.items.Count -gt 0) {
            $first = $ing.items[0]
            $ingName = $first.metadata.name
            $addr = $first.status.loadBalancer.ingress[0]
            $addrText = if ($addr.ip) { $addr.ip } elseif ($addr.hostname) { $addr.hostname } else { '' }
            Write-Host "Ingress detected: $ingName"
            if ($addrText) { Write-Host "Ingress address: $addrText" }
        }
    }
} catch {
    Warn "Could not parse ingress JSON: $($_.Exception.Message)"
}

$externalOk = $false
$hostResolvable = $false
$port = if ($scheme -eq 'https') { 443 } else { 80 }

try {
    $resolved = Try-ResolveHost $env:DD_HOST
    if ($resolved -and $resolved.Count -gt 0) {
        $hostResolvable = $true
    }
} catch {}

if ($hostResolvable -and (Test-TcpConnect -Host $env:DD_HOST -Port $port -TimeoutMs 3000)) {
    Write-Host 'Checking whether the UI is reachable (best-effort, external)...'
    try {
        $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 15 -UseBasicParsing
        Write-Host "UI HTTP status: $($resp.StatusCode)"
        $externalOk = $true
    } catch {
        Warn "UI check failed from agent (DNS/LB may not be ready): $($_.Exception.Message)"
    }
} else {
    Warn "Skipping external UI check: '$($env:DD_HOST)' is not resolvable/reachable from agent (port $port)."
}

Write-Host 'Running in-cluster smoke test (fallback)...'
$podName = 'dd-smoke'
try {
    kubectl -n $namespace delete pod $podName --ignore-not-found=true --wait=false 2>$null | Out-Null
    kubectl -n $namespace run $podName --image=curlimages/curl:8.5.0 --restart=Never --command -- sleep 3600 | Out-Host
    kubectl -n $namespace wait --for=condition=Ready pod/$podName --timeout=120s | Out-Host

    $code = kubectl -n $namespace exec $podName -- curl -s -o /dev/null -w "%{http_code}" http://defectdojo-django:8080/login
    $codeText = ($code | Out-String).Trim()
    Write-Host "In-cluster smoke HTTP code: $codeText"

    if ($codeText -ne '200' -and $codeText -ne '302') {
        Warn "In-cluster smoke test returned unexpected HTTP code '$codeText' (expected 200 or 302)."
    }
} catch {
    Warn "In-cluster smoke test failed: $($_.Exception.Message)"
} finally {
    kubectl -n $namespace delete pod $podName --ignore-not-found=true --wait=false 2>$null | Out-Null
}
