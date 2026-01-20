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

Write-Host 'Waiting for DefectDojo bootstrap job to complete (up to 20 minutes)...'
kubectl -n $namespace get jobs | Out-Host
Assert-LastExitCode 'kubectl get jobs'

$bootstrapSelector = 'cvm.defectdojo/component=bootstrap'
$initializerSelector = 'defectdojo.org/component=initializer'

$selector = $null
try {
    $bootstrapJobsJson = kubectl get job -n $namespace -l $bootstrapSelector -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $bootstrapJobsJson) {
        $bootstrapJobs = $bootstrapJobsJson | ConvertFrom-Json
        if (@($bootstrapJobs.items).Count -gt 0) { $selector = $bootstrapSelector }
    }
} catch {}

if (-not $selector) {
    try {
        $initJobsJson = kubectl get job -n $namespace -l $initializerSelector -o json 2>$null
        if ($LASTEXITCODE -eq 0 -and $initJobsJson) {
            $initJobs = $initJobsJson | ConvertFrom-Json
            if (@($initJobs.items).Count -gt 0) { $selector = $initializerSelector }
        }
    } catch {}
}

if (-not $selector) {
    Warn 'No bootstrap/initializer job found; continuing (install stage may have already completed initialization).'
} else {
    Write-Host "Using job selector: $selector"
}
$start = Get-Date
$timeoutAt = $start.AddMinutes(20)
$lastStatus = ''

while ($selector -and ((Get-Date) -lt $timeoutAt)) {
    $jobJson = kubectl get job -n $namespace -l $selector -o json 2>$null
    if ($LASTEXITCODE -ne 0) {
        Fail 'kubectl get job for selected job selector failed.'
    }

    $jobs = $null
    try { $jobs = $jobJson | ConvertFrom-Json } catch { Fail "Failed to parse initializer job JSON: $($_.Exception.Message)" }
    $items = @($jobs.items)
    if ($items.Count -eq 0) {
        Start-Sleep -Seconds 5
        continue
    }

    $job = $items | Sort-Object { $_.metadata.creationTimestamp } | Select-Object -Last 1
    $name = $job.metadata.name

    $backoffLimit = 6
    if ($job.PSObject.Properties.Match('spec').Count -gt 0 -and $job.spec) {
        if ($job.spec.PSObject.Properties.Match('backoffLimit').Count -gt 0 -and $null -ne $job.spec.backoffLimit) {
            $backoffLimit = [int]$job.spec.backoffLimit
        }
    }

    $active = 0
    $succeeded = 0
    $failed = 0
    if ($job.PSObject.Properties.Match('status').Count -gt 0 -and $job.status) {
        if ($job.status.PSObject.Properties.Match('active').Count -gt 0 -and $job.status.active) { $active = [int]$job.status.active }
        if ($job.status.PSObject.Properties.Match('succeeded').Count -gt 0 -and $job.status.succeeded) { $succeeded = [int]$job.status.succeeded }
        if ($job.status.PSObject.Properties.Match('failed').Count -gt 0 -and $job.status.failed) { $failed = [int]$job.status.failed }
    }

    $isFailed = $false
    if ($job.PSObject.Properties.Match('status').Count -gt 0 -and $job.status -and $job.status.PSObject.Properties.Match('conditions').Count -gt 0 -and $job.status.conditions) {
        foreach ($cond in @($job.status.conditions)) {
            if ($cond -and $cond.type -eq 'Failed' -and $cond.status -eq 'True') { $isFailed = $true; break }
        }
    }

    $status = "job=$name active=$active succeeded=$succeeded failed=$failed backoffLimit=$backoffLimit"
    if ($status -ne $lastStatus) {
        Write-Host $status
        $lastStatus = $status
    } elseif (((Get-Date) - $start).TotalSeconds % 30 -lt 6) {
        Write-Host $status
    }

    if ($succeeded -ge 1) {
        Write-Host 'Job completed.'
        break
    }

    if ($isFailed -or ($failed -gt $backoffLimit)) {
        Warn 'Job failed (final). Capturing diagnostics...'
        try { kubectl -n $namespace describe job $name | Out-Host } catch {}
        try {
            kubectl -n $namespace get pods -l job-name=$name -o wide | Out-Host
            $podNames = (kubectl -n $namespace get pods -l job-name=$name -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>$null | Out-String).Trim() -split "`n" |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            foreach ($p in $podNames) {
                Write-Host "--- describe pod/$p"
                try { kubectl -n $namespace describe pod $p | Out-Host } catch {}
                Write-Host "--- logs pod/$p (all containers, best-effort)"
                try { kubectl -n $namespace logs $p --all-containers --tail=200 | Out-Host } catch {}
                Write-Host "--- logs pod/$p (init wait-for-db, best-effort)"
                try { kubectl -n $namespace logs $p -c wait-for-db --tail=200 | Out-Host } catch {}
            }
        } catch {}
        try { kubectl -n $namespace logs job/$name --all-containers --tail=200 | Out-Host } catch {}
        Fail 'Job failed.'
    }

    Start-Sleep -Seconds 10
}

if ($selector -and ((Get-Date) -ge $timeoutAt)) {
    Warn 'Job did not complete within 20 minutes. Capturing diagnostics...'
    try { kubectl -n $namespace get events --sort-by=.lastTimestamp | Select-Object -Last 40 | Out-Host } catch {}
    try {
        $jobName = (kubectl -n $namespace get job -l $selector -o jsonpath='{.items[-1:].metadata.name}' 2>$null | Out-String).Trim()
        if ($jobName) { kubectl -n $namespace logs job/$jobName --all-containers --tail=200 | Out-Host }
    } catch {}
    Fail 'Job timed out.'
}

Write-Host "DefectDojo URL (from DD_HOST): $url"

Write-Host 'Determining ingress controller external address (ingress-nginx)...'
$svcExists = $false
try {
    $null = kubectl -n ingress-nginx get svc ingress-nginx-controller 2>$null
    $svcExists = $LASTEXITCODE -eq 0
} catch {}

if ($svcExists) {
    # On AKS, the Azure Load Balancer health probe defaults to GET / on the nodePort.
    # ingress-nginx returns 404 on / by default, which can mark all backends unhealthy and make the public IP look unreachable.
    # Force the probe to use /healthz (200).
    try {
        kubectl -n ingress-nginx annotate svc ingress-nginx-controller `
            service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path='/healthz' --overwrite | Out-Null
    } catch {
        Warn "Failed to annotate ingress-nginx-controller health probe path: $($_.Exception.Message)"
    }

    # Optional: restrict ingress to specific client CIDRs (comma-separated), e.g. '78.80.81.243/32,168.63.129.16/32'.
    if (-not [string]::IsNullOrWhiteSpace($env:INGRESS_SOURCE_RANGES)) {
        $ranges = @(
            $env:INGRESS_SOURCE_RANGES.Split(',') |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        if ($ranges.Count -gt 0) {
            $patchObj = @{ spec = @{ loadBalancerSourceRanges = $ranges } } | ConvertTo-Json -Depth 6 -Compress
            try {
                kubectl -n ingress-nginx patch svc ingress-nginx-controller --type merge -p $patchObj | Out-Null
            } catch {
                Warn "Failed to patch ingress-nginx-controller loadBalancerSourceRanges: $($_.Exception.Message)"
            }
        }
    }
}

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
