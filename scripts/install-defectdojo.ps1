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

function Patch-WorkloadStability() {
    Write-Host 'Patching DefectDojo workloads for stability (db-migration-checker resources + Django probes)...'

    $initPatch = @'
{"spec":{"template":{"spec":{"initContainers":[{"name":"db-migration-checker","resources":{"requests":{"cpu":"10m","memory":"256Mi"},"limits":{"cpu":"200m","memory":"512Mi"}}}]}}}}
'@

    foreach ($d in @('defectdojo-django', 'defectdojo-celery-worker', 'defectdojo-celery-beat')) {
        kubectl -n $namespace patch deploy $d --type='strategic' -p $initPatch | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "kubectl patch deploy/$d (init container resources) failed." }
    }

        # Probes: keep them lightweight to avoid flapping during high load.
        # - uWSGI: use tcpSocket probes (avoid slow HTTP endpoints)
        # - nginx: readiness should only check nginx itself (not upstream uWSGI)
        # - remove nginx startupProbe (it can cause unnecessary restarts when uWSGI is briefly unavailable)
        $djangoProbeJsonPatch = @'
[
    {"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{
        "requests":{"cpu":"25m","memory":"512Mi"},
        "limits":{"cpu":"1","memory":"1Gi"}
    }},
    {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe","value":{
        "tcpSocket":{"port":8081},
        "initialDelaySeconds":120,
        "timeoutSeconds":2,
        "periodSeconds":20,
        "successThreshold":1,
        "failureThreshold":6
    }},
    {"op":"add","path":"/spec/template/spec/containers/0/readinessProbe","value":{
        "tcpSocket":{"port":8081},
        "initialDelaySeconds":10,
        "timeoutSeconds":2,
        "periodSeconds":10,
        "successThreshold":1,
        "failureThreshold":3
    }},
    {"op":"add","path":"/spec/template/spec/containers/0/startupProbe","value":{
        "tcpSocket":{"port":8081},
        "initialDelaySeconds":30,
        "timeoutSeconds":2,
        "periodSeconds":10,
        "successThreshold":1,
        "failureThreshold":30
    }},
    {"op":"replace","path":"/spec/template/spec/containers/1/readinessProbe","value":{
        "httpGet":{"path":"/nginx_health","port":"http","scheme":"HTTP","httpHeaders":[{"name":"Host","value":"defectdojo.local"}]},
        "initialDelaySeconds":10,
        "timeoutSeconds":2,
        "periodSeconds":10,
        "successThreshold":1,
        "failureThreshold":3
    }},
    {"op":"remove","path":"/spec/template/spec/containers/1/startupProbe"}
]
'@

        kubectl -n $namespace patch deploy defectdojo-django --type='json' -p $djangoProbeJsonPatch | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail 'kubectl patch deploy/defectdojo-django (probes) failed.' }
}

function Invoke-PostgresSql([string]$Sql) {
    $pgPod = 'defectdojo-postgresql-0'
    $cmd = @(
        'exec',
        '-n', $namespace,
        $pgPod,
        '--',
        'bash', '-lc',
        ('export PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgresql-password)"; /opt/bitnami/postgresql/bin/psql -U defectdojo -d defectdojo -v ON_ERROR_STOP=1 -c "' + $Sql.Replace('"','\"') + '"')
    )
    & kubectl @cmd | Out-Host
    Assert-LastExitCode 'psql'
}

function Reset-DatabaseIfSystemSettingsInvalid() {
    Write-Host 'Pre-flight: validating system settings table state...'

    $pgPod = 'defectdojo-postgresql-0'
    $toRegclass = (& kubectl exec -n $namespace $pgPod -- bash -lc 'export PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgresql-password)"; /opt/bitnami/postgresql/bin/psql -U defectdojo -d defectdojo -At -c "SELECT to_regclass(''public.dojo_system_settings'');"' 2>$null | Out-String).Trim()

    $systemSettingsMigrationCount = 0
    try {
        $migCnt = (& kubectl exec -n $namespace $pgPod -- bash -lc 'export PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgresql-password)"; /opt/bitnami/postgresql/bin/psql -U defectdojo -d defectdojo -At -c "SELECT COUNT(*) FROM django_migrations WHERE app=''dojo'' AND name ILIKE ''%system_settings%'';"' 2>$null | Out-String).Trim()
        if ($migCnt -match '^[0-9]+$') { $systemSettingsMigrationCount = [int]$migCnt }
    } catch {}

    $rowCount = $null
    if ($toRegclass) {
        try {
            $cntText = (& kubectl exec -n $namespace $pgPod -- bash -lc 'export PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgresql-password)"; /opt/bitnami/postgresql/bin/psql -U defectdojo -d defectdojo -At -c "SELECT COUNT(*) FROM dojo_system_settings;"' 2>$null | Out-String).Trim()
            if ($cntText -match '^[0-9]+$') { $rowCount = [int]$cntText }
        } catch {}
    }

    $inconsistent = $false
    if (-not $toRegclass -and $systemSettingsMigrationCount -gt 0) {
        Write-Host "Detected inconsistent DB: dojo_system_settings is missing but $systemSettingsMigrationCount system_settings migrations are already applied."
        $inconsistent = $true
    }
    if ($toRegclass -and $null -ne $rowCount -and $rowCount -eq 0) {
        Write-Host 'Detected inconsistent DB: dojo_system_settings exists but is empty (upstream initializer can crash; migrations may also break).'
        $inconsistent = $true
    }

    if (-not $inconsistent) {
        Write-Host 'System settings table looks consistent (no DB reset needed).'
        return
    }

    Write-Warning 'Resetting PostgreSQL public schema to recover from inconsistent DefectDojo migration state (DESTRUCTIVE).'
    Invoke-PostgresSql "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO defectdojo; GRANT ALL ON SCHEMA public TO public;"
}

function Run-BootstrapJobAndWait() {
    $jobName = 'defectdojo-cvm-bootstrap'
    $image = 'defectdojo/defectdojo-django:2.53.5'

    Write-Host "Creating pipeline bootstrap Job '$jobName' (replaces chart initializer)..."
    kubectl -n $namespace delete job $jobName --ignore-not-found=true | Out-Null

    $jobYaml = @"
apiVersion: batch/v1
kind: Job
metadata:
  name: $jobName
  namespace: $namespace
  labels:
    app.kubernetes.io/instance: $releaseName
    app.kubernetes.io/name: defectdojo
    cvm.defectdojo/component: bootstrap
spec:
  backoffLimit: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: $releaseName
        app.kubernetes.io/name: defectdojo
        cvm.defectdojo/component: bootstrap
    spec:
      restartPolicy: Never
      serviceAccountName: defectdojo
      initContainers:
        - name: wait-for-db
          image: $image
          imagePullPolicy: IfNotPresent
          command: ['/bin/bash','-lc','/wait-for-it.sh "`$DD_DATABASE_HOST:`$DD_DATABASE_PORT" -t 300 -s -- /bin/echo Database is up']
          envFrom:
            - configMapRef:
                name: $releaseName
            - secretRef:
                name: $releaseName-extrasecrets
                optional: true
          env:
            - name: DD_ENABLE_AUDITLOG
              value: 'False'
            - name: DD_INITIALIZE
              value: 'true'
      containers:
        - name: bootstrap
          image: $image
          imagePullPolicy: IfNotPresent
          command: ['/entrypoint-initializer.sh']
          envFrom:
            - configMapRef:
                name: $releaseName
            - secretRef:
                name: $releaseName
                optional: true
            - secretRef:
                name: $releaseName-extrasecrets
                optional: true
          env:
            - name: DD_DATABASE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: defectdojo-postgresql-specific
                  key: postgresql-password
            - name: DD_ENABLE_AUDITLOG
              value: 'False'
            - name: DD_INITIALIZE
              value: 'true'
"@

    $jobYaml | kubectl apply -f - | Out-Host
    Assert-LastExitCode 'kubectl apply bootstrap job'

    Write-Host 'Waiting for bootstrap job to complete...'
    $selector = 'cvm.defectdojo/component=bootstrap'
    $sawJob = $false
    $start = Get-Date
    $timeoutAt = $start.AddMinutes(20)
    $lastStatusLine = ''

    while ((Get-Date) -lt $timeoutAt) {
        $jobJson = kubectl get job -n $namespace -l $selector -o json 2>$null
        if ($LASTEXITCODE -ne 0) { Fail 'kubectl get job for bootstrap selector failed.' }
        $jobs = $jobJson | ConvertFrom-Json
        $items = @($jobs.items)
        if ($items.Count -eq 0) {
            Start-Sleep -Seconds 5
            continue
        }

        $sawJob = $true
        $job = $items | Sort-Object { $_.metadata.creationTimestamp } | Select-Object -Last 1
        $name = $job.metadata.name

        $backoffLimit = 6
        if ($job.PSObject.Properties.Match('spec').Count -gt 0 -and $job.spec) {
            if ($job.spec.PSObject.Properties.Match('backoffLimit').Count -gt 0 -and $null -ne $job.spec.backoffLimit) { $backoffLimit = [int]$job.spec.backoffLimit }
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

        $statusLine = "bootstrap job=$name active=$active succeeded=$succeeded failed=$failed backoffLimit=$backoffLimit"
        if ($statusLine -ne $lastStatusLine) {
            Write-Host $statusLine
            $lastStatusLine = $statusLine
        } elseif (((Get-Date) - $start).TotalSeconds % 30 -lt 6) {
            Write-Host $statusLine
        }

        if ($succeeded -ge 1) {
            Write-Host 'Bootstrap job completed.'
            return
        }

        if ($isFailed -or ($failed -gt $backoffLimit)) {
            Write-Host 'Bootstrap job failed (final). Capturing diagnostics...'
            kubectl describe job -n $namespace $name | Out-Host
            kubectl logs -n $namespace job/$name --all-containers --tail=250 | Out-Host
            Fail 'Bootstrap job failed.'
        }

        Start-Sleep -Seconds 10
    }

    if ($sawJob) {
        Write-Host 'Bootstrap job did not complete within 20 minutes. Recent events:'
        kubectl get events -n $namespace --sort-by=.lastTimestamp | Select-Object -Last 40 | Out-Host
    }
    Fail 'Bootstrap job timed out.'
}

Reset-DatabaseIfSystemSettingsInvalid
Run-BootstrapJobAndWait

Patch-WorkloadStability

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
    kubectl rollout status deployment/$deployment -n $namespace --timeout=20m --watch=true | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "kubectl rollout status deployment/$deployment returned exit code $LASTEXITCODE. Falling back to kubectl wait..."
        kubectl wait -n $namespace --for=condition=Available deployment/$deployment --timeout=20m | Out-Host
        Assert-LastExitCode "kubectl wait deployment/$deployment"
    }
}
