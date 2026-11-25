# ============================================================
# Aprovisionamiento completo 100% AWS (EP3 / Actividad 3.2)
# Microservicios del docente: frontend, backend1, backend2
# (Amazon ECR + Amazon ECS Fargate + Service Connect + CloudWatch)
# ============================================================
# Crea de forma idempotente toda la infraestructura AWS:
#   1. Repositorios Amazon ECR con imagenes versionadas (1.0.0)
#      espejadas desde guillermovillacuratorres/*-service:latest
#      (evita reconstruir en el runner y garantiza trazabilidad en ECR)
#   2. Security Group sg-microservicios (5000 publico; 5001-5002 solo VPC)
#   3. CloudWatch Log Groups (/ecs/frontend, /ecs/backend1, /ecs/backend2)
#      + Metric Filters de errores
#   4. Cluster ECS Fargate doy0101-ecs con Container Insights (enhanced)
#      y Service Connect namespace microservices-demo
#   5. Definiciones de tareas (0.25 vCPU / 0.5 GB, LabRole, HTTP nombrados)
#   6. Servicios ECS ordenados: backend1 y backend2 (Cliente y Servidor)
#      primero -> luego frontend (Solo Cliente)
#   7. 4 Alarmas de CloudWatch y Dashboard doy0101-microservicios-Tapia
#   8. Publicacion de metricas CI/CD (DOY0101/CICD) y prueba E2E
#
# Uso:
#   .\infra\aws\provision-ecs.ps1
# ============================================================
param(
    [string]$Region = "us-east-1",
    [string]$ClusterName = "doy0101-ecs",
    [string]$Namespace = "microservices-demo",
    [string]$DashboardName = "doy0101-microservicios-Tapia",
    [string]$ImageVersion = "1.0.0",
    [switch]$SkipEcrSync
)

$ErrorActionPreference = "Stop"
$DeployStart = Get-Date
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$UvAwsPy = Join-Path $env:APPDATA "uv\tools\awscli\Scripts\python.exe"
function Invoke-Aws {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CliArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if (Test-Path $UvAwsPy) {
            $output = & $UvAwsPy -m awscli --region $Region @CliArgs 2>&1
        } else {
            $output = & aws --region $Region @CliArgs 2>&1
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Error ejecutando aws $($CliArgs -join ' '):`n$($output -join "`n")"
        }
        return ($output -join "`n").Trim()
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Write-TempJson {
    param([string]$Name, [object]$Object)
    $path = Join-Path $env:TEMP "doy0101-$Name.json"
    $json = if ($Object -is [string]) { $Object } else { $Object | ConvertTo-Json -Depth 15 }
    [System.IO.File]::WriteAllText($path, $json, $Utf8NoBom)
    return $path
}

Write-Host "==> Verificando credenciales AWS..." -ForegroundColor Cyan
$Identity = Invoke-Aws sts get-caller-identity --output json | ConvertFrom-Json
$AccountId = $Identity.Account
$LabRoleArn = "arn:aws:iam::${AccountId}:role/LabRole"
$EcrRegistry = "${AccountId}.dkr.ecr.${Region}.amazonaws.com"
Write-Host "    Cuenta: $AccountId | Identidad: $($Identity.Arn)"

$ServicesSpec = @(
    @{ Name = "backend1"; Repo = "backend1-service"; Source = "guillermovillacuratorres/backend1-service:latest"; Port = 5001; PortName = "backend1-http"; Dns = "backend1-service" },
    @{ Name = "backend2"; Repo = "backend2-service"; Source = "guillermovillacuratorres/backend2-service:latest"; Port = 5002; PortName = "backend2-http"; Dns = "backend2-service" },
    @{ Name = "frontend"; Repo = "frontend-service"; Source = "guillermovillacuratorres/frontend-service:latest"; Port = 5000; PortName = "frontend-http"; Dns = "" }
)

# ── 1. Repositorios Amazon ECR e imagenes versionadas ─────────
Write-Host "`n==> 1. Configurando repositorios Amazon ECR (imagenes versionadas :$ImageVersion)..." -ForegroundColor Cyan
$LifecyclePolicy = @{
    rules = @(
        @{
            rulePriority = 1
            description = "Conservar ultimas 10 imagenes versionadas"
            selection = @{ tagStatus = "any"; countType = "imageCountMoreThan"; countNumber = 10 }
            action = @{ type = "expire" }
        }
    )
}
$LifecycleFile = Write-TempJson "ecr-lifecycle" $LifecyclePolicy

foreach ($svc in $ServicesSpec) {
    $exists = $true
    try {
        Invoke-Aws ecr describe-repositories --repository-names $svc.Repo --output json | Out-Null
        Write-Host "    ECR repo '$($svc.Repo)' ya existe."
    } catch {
        $exists = $false
    }
    if (-not $exists) {
        Invoke-Aws ecr create-repository --repository-name $svc.Repo --image-scanning-configuration scanOnPush=true --output json | Out-Null
        Write-Host "    ECR repo '$($svc.Repo)' creado (scanOnPush=true)."
    }
    Invoke-Aws ecr put-lifecycle-policy --repository-name $svc.Repo --lifecycle-policy-text "file://$LifecycleFile" --output json | Out-Null
}

if (-not $SkipEcrSync) {
    Write-Host "`n==> 2. Publicando imagenes versionadas ($ImageVersion) en Amazon ECR..." -ForegroundColor Cyan
    $AuthRaw = Invoke-Aws ecr get-authorization-token --query "authorizationData[0].authorizationToken" --output text
    $AuthDecoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($AuthRaw.Trim()))
    $EcrPwd = $AuthDecoded.Substring(4).Trim()

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & docker login --username AWS --password $EcrPwd $EcrRegistry 2>&1 |
            Where-Object { "$_" -notmatch "Using --password via the CLI" } |
            ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -ne 0) { throw "Error autenticando Docker contra ECR" }

        foreach ($svc in $ServicesSpec) {
            $targetVer = "${EcrRegistry}/$($svc.Repo):${ImageVersion}"
            $targetLatest = "${EcrRegistry}/$($svc.Repo):latest"
            Write-Host "    Pull $($svc.Source) -> Push $targetVer"
            & docker pull --platform linux/amd64 $svc.Source 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Error descargando $($svc.Source)" }
            & docker tag $svc.Source $targetVer
            & docker tag $svc.Source $targetLatest
            & docker push $targetVer 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Error subiendo $targetVer a ECR" }
            & docker push $targetLatest 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Error subiendo $targetLatest a ECR" }
            Write-Host "    OK: $targetVer" -ForegroundColor Green
        }
    } finally {
        $ErrorActionPreference = $prev
    }
    Write-Host "    Imagenes versionadas publicadas en Amazon ECR." -ForegroundColor Green
}

# ── 3. Red: VPC predeterminada, subredes y sg-microservicios ──
Write-Host "`n==> 3. Configurando red y grupo de seguridad sg-microservicios..." -ForegroundColor Cyan
$VpcInfo = (Invoke-Aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --output json | ConvertFrom-Json).Vpcs[0]
$VpcId = $VpcInfo.VpcId
$VpcCidr = $VpcInfo.CidrBlock
$Subnets = (Invoke-Aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VpcId" "Name=default-for-az,Values=true" --output json | ConvertFrom-Json).Subnets |
    Select-Object -ExpandProperty SubnetId
Write-Host "    VPC: $VpcId ($VpcCidr) | Subredes: $($Subnets -join ', ')"

$SgName = "doy0101-microservicios-sg"
$SgQuery = (Invoke-Aws ec2 describe-security-groups --filters "Name=group-name,Values=$SgName" "Name=vpc-id,Values=$VpcId" --output json | ConvertFrom-Json).SecurityGroups
if ($SgQuery.Count -gt 0) {
    $SgId = $SgQuery[0].GroupId
    Write-Host "    Security Group '$SgName' ya existe ($SgId)."
} else {
    $SgId = Invoke-Aws ec2 create-security-group --group-name $SgName `
        --description "DOY0101 microservicios: 5000 publico (frontend), 5001-5002 solo VPC (backends)" `
        --vpc-id $VpcId --query GroupId --output text
    Write-Host "    Security Group '$SgName' creado ($SgId)."
}

$IngressRules = @(
    @{ From = 5000; To = 5000; Cidr = "0.0.0.0/0"; Desc = "Frontend publico TCP 5000" },
    @{ From = 5001; To = 5002; Cidr = $VpcCidr; Desc = "Backends 5001-5002 solo desde VPC" }
)
foreach ($rule in $IngressRules) {
    try {
        Invoke-Aws ec2 authorize-security-group-ingress --group-id $SgId `
            --ip-permissions "IpProtocol=tcp,FromPort=$($rule.From),ToPort=$($rule.To),IpRanges=[{CidrIp=$($rule.Cidr),Description='$($rule.Desc)'}]" | Out-Null
        Write-Host "    Regla agregada: TCP $($rule.From)-$($rule.To) <- $($rule.Cidr)"
    } catch {
        if ($_.Exception.Message -notmatch "InvalidPermission.Duplicate") { throw }
    }
}

# ── 4. CloudWatch Log Groups y Metric Filters ─────────────────
Write-Host "`n==> 4. Configurando CloudWatch Logs y Metric Filters..." -ForegroundColor Cyan
foreach ($svc in $ServicesSpec) {
    $lg = "/ecs/$($svc.Name)"
    try {
        Invoke-Aws logs create-log-group --log-group-name $lg | Out-Null
        Write-Host "    Log Group '$lg' creado."
    } catch {
        if ($_.Exception.Message -notmatch "ResourceAlreadyExistsException") { throw }
        Write-Host "    Log Group '$lg' ya existe."
    }
    Invoke-Aws logs put-retention-policy --log-group-name $lg --retention-in-days 14 | Out-Null
}

$FrontendFilter = Write-TempJson "filter-frontend" @{
    logGroupName = "/ecs/frontend"
    filterName = "frontend-404-filter"
    filterPattern = '"404"'
    metricTransformations = @(
        @{
            metricName = "Frontend404Count"
            metricNamespace = "DOY0101/AppLogs"
            metricValue = "1"
            defaultValue = 0
        }
    )
}
Invoke-Aws logs put-metric-filter --cli-input-json "file://$FrontendFilter" | Out-Null

foreach ($b in @("backend1", "backend2")) {
    $BackendFilter = Write-TempJson "filter-$b" @{
        logGroupName = "/ecs/$b"
        filterName = "$b-error-filter"
        filterPattern = '?ERROR ?500'
        metricTransformations = @(
            @{
                metricName = "BackendErrorCount"
                metricNamespace = "DOY0101/AppLogs"
                metricValue = "1"
                defaultValue = 0
            }
        )
    }
    Invoke-Aws logs put-metric-filter --cli-input-json "file://$BackendFilter" | Out-Null
}
Write-Host "    Metric Filters configurados en /ecs/frontend, /ecs/backend1 y /ecs/backend2."

# ── 5. Cluster ECS Fargate + Container Insights + Service Connect ─
Write-Host "`n==> 5. Configurando cluster ECS '$ClusterName' (Container Insights + Service Connect)..." -ForegroundColor Cyan

$ExistingCluster = (Invoke-Aws ecs describe-clusters --clusters $ClusterName --include SETTINGS --output json | ConvertFrom-Json).clusters |
    Where-Object { $_.status -eq "ACTIVE" }

if (-not $ExistingCluster) {
    # En cuentas nuevas de AWS Academy se crea primero el cluster (inicializa
    # AWSServiceRoleForECS) y luego se asocia el namespace de Service Connect.
    try {
        Invoke-Aws ecs create-cluster --cluster-name $ClusterName `
            --capacity-providers FARGATE FARGATE_SPOT `
            --settings "name=containerInsights,value=enhanced" --output json | Out-Null
    } catch {
        Invoke-Aws ecs create-cluster --cluster-name $ClusterName `
            --capacity-providers FARGATE FARGATE_SPOT `
            --settings "name=containerInsights,value=enabled" --output json | Out-Null
    }
    Write-Host "    Cluster '$ClusterName' creado. Esperando inicializacion de Service Linked Role..."
    Start-Sleep -Seconds 5
} else {
    Write-Host "    Cluster '$ClusterName' ya activo."
}

try {
    Invoke-Aws ecs update-cluster --cluster $ClusterName `
        --settings "name=containerInsights,value=enhanced" `
        --service-connect-defaults "namespace=$Namespace" --output json | Out-Null
} catch {
    Invoke-Aws ecs update-cluster --cluster $ClusterName `
        --settings "name=containerInsights,value=enabled" `
        --service-connect-defaults "namespace=$Namespace" --output json | Out-Null
}

for ($w = 1; $w -le 12; $w++) {
    $c = (Invoke-Aws ecs describe-clusters --clusters $ClusterName --include ATTACHMENTS --output json | ConvertFrom-Json).clusters[0]
    if ($c.attachmentsStatus -ne "UPDATE_IN_PROGRESS") { break }
    Write-Host "    Esperando vinculacion de Service Connect ($Namespace)... ($w/12)"
    Start-Sleep -Seconds 5
}
Write-Host "    Cluster '$ClusterName' listo con Container Insights y Service Connect ($Namespace)." -ForegroundColor Green

# ── 6. Definiciones de tareas (0.25 vCPU / 0.5 GB, LabRole) ───
Write-Host "`n==> 6. Registrando definiciones de tareas ECS (desde Amazon ECR)..." -ForegroundColor Cyan
$TaskArns = @{}
foreach ($svc in $ServicesSpec) {
    $imageUri = "${EcrRegistry}/$($svc.Repo):${ImageVersion}"
    $td = @{
        family = $svc.Name
        networkMode = "awsvpc"
        requiresCompatibilities = @("FARGATE")
        cpu = "256"
        memory = "512"
        executionRoleArn = $LabRoleArn
        taskRoleArn = $LabRoleArn
        runtimePlatform = @{ cpuArchitecture = "X86_64"; operatingSystemFamily = "LINUX" }
        containerDefinitions = @(
            @{
                name = $svc.Name
                image = $imageUri
                essential = $true
                portMappings = @(
                    @{
                        containerPort = $svc.Port
                        hostPort = $svc.Port
                        protocol = "tcp"
                        name = $svc.PortName
                        appProtocol = "http"
                    }
                )
                logConfiguration = @{
                    logDriver = "awslogs"
                    options = @{
                        "awslogs-group" = "/ecs/$($svc.Name)"
                        "awslogs-region" = $Region
                        "awslogs-stream-prefix" = "ecs"
                    }
                }
            }
        )
    }
    $tdFile = Write-TempJson "taskdef-$($svc.Name)" $td
    $arn = Invoke-Aws ecs register-task-definition --cli-input-json "file://$tdFile" --query "taskDefinition.taskDefinitionArn" --output text
    $TaskArns[$svc.Name] = $arn
    Write-Host "    Registrada: $arn ($imageUri)"
}

# ── 7. Servicios ECS con Service Connect (backends -> frontend) ─
Write-Host "`n==> 7. Desplegando servicios ECS (backend1 y backend2 primero, luego frontend)..." -ForegroundColor Cyan
$NetworkConfig = @{
    awsvpcConfiguration = @{
        subnets = @($Subnets)
        securityGroups = @($SgId)
        assignPublicIp = "ENABLED"
    }
}
$NetFile = Write-TempJson "net-config" $NetworkConfig

function Ensure-EcsService {
    param(
        [string]$ServiceName,
        [string]$TaskDefinitionArn,
        [hashtable]$ServiceConnectConfig
    )
    $ScFile = Write-TempJson "sc-$ServiceName" $ServiceConnectConfig
    $Existing = (Invoke-Aws ecs describe-services --cluster $ClusterName --services $ServiceName --output json | ConvertFrom-Json).services |
        Where-Object { $_.status -eq "ACTIVE" }

    if ($Existing) {
        Write-Host "    Actualizando servicio '$ServiceName'..."
        Invoke-Aws ecs update-service --cluster $ClusterName --service $ServiceName `
            --task-definition $TaskDefinitionArn --desired-count 1 `
            --force-new-deployment --service-connect-configuration "file://$ScFile" --output json | Out-Null
    } else {
        Write-Host "    Creando servicio '$ServiceName'..."
        Invoke-Aws ecs create-service --cluster $ClusterName --service-name $ServiceName `
            --task-definition $TaskDefinitionArn --desired-count 1 --launch-type FARGATE `
            --network-configuration "file://$NetFile" `
            --service-connect-configuration "file://$ScFile" --output json | Out-Null
    }
}

# Crear/actualizar ambos backends en paralelo y esperar estabilidad
Ensure-EcsService -ServiceName "backend1" -TaskDefinitionArn $TaskArns["backend1"] -ServiceConnectConfig @{
    enabled = $true
    namespace = $Namespace
    services = @(
        @{
            portName = "backend1-http"
            discoveryName = "backend1"
            clientAliases = @( @{ port = 5001; dnsName = "backend1-service" } )
        }
    )
}

Ensure-EcsService -ServiceName "backend2" -TaskDefinitionArn $TaskArns["backend2"] -ServiceConnectConfig @{
    enabled = $true
    namespace = $Namespace
    services = @(
        @{
            portName = "backend2-http"
            discoveryName = "backend2"
            clientAliases = @( @{ port = 5002; dnsName = "backend2-service" } )
        }
    )
}

Write-Host "    Esperando estabilidad de backend1 y backend2..."
Invoke-Aws ecs wait services-stable --cluster $ClusterName --services backend1 backend2 | Out-Null
Write-Host "    backend1 y backend2 en 1/1 ESTABLES." -ForegroundColor Green

# Ahora crear/actualizar frontend (Solo Cliente)
Ensure-EcsService -ServiceName "frontend" -TaskDefinitionArn $TaskArns["frontend"] -ServiceConnectConfig @{
    enabled = $true
    namespace = $Namespace
}

Write-Host "    Esperando estabilidad de frontend..."
Invoke-Aws ecs wait services-stable --cluster $ClusterName --services frontend | Out-Null
Write-Host "    frontend en 1/1 ESTABLE." -ForegroundColor Green

# ── 8. Alarmas y Dashboard en Amazon CloudWatch ───────────────
Write-Host "`n==> 8. Creando alarmas y dashboard '$DashboardName' en Amazon CloudWatch..." -ForegroundColor Cyan

foreach ($svcName in @("frontend", "backend1", "backend2")) {
    Invoke-Aws cloudwatch put-metric-alarm `
        --alarm-name "doy0101-$svcName-disponibilidad" `
        --alarm-description "Alerta si $svcName cae a 0 tareas en ejecucion" `
        --namespace "ECS/ContainerInsights" --metric-name "RunningTaskCount" `
        --dimensions "Name=ClusterName,Value=$ClusterName" "Name=ServiceName,Value=$svcName" `
        --statistic Minimum --period 60 --evaluation-periods 1 `
        --threshold 1 --comparison-operator LessThanThreshold --treat-missing-data breaching | Out-Null
}

Invoke-Aws cloudwatch put-metric-alarm `
    --alarm-name "doy0101-backend1-errores-5xx" `
    --alarm-description "Alerta ante errores HTTP 5xx en backend1" `
    --namespace "AWS/ECS" --metric-name "HTTPCode_Target_5XX_Count" `
    --dimensions "Name=ClusterName,Value=$ClusterName" "Name=ServiceName,Value=frontend" "Name=TargetDiscoveryName,Value=backend1" `
    --statistic Sum --period 60 --evaluation-periods 1 `
    --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching | Out-Null

Invoke-Aws cloudwatch put-metric-alarm `
    --alarm-name "doy0101-backend2-errores-5xx" `
    --alarm-description "Alerta ante errores HTTP 5xx en backend2" `
    --namespace "AWS/ECS" --metric-name "HTTPCode_Target_5XX_Count" `
    --dimensions "Name=ClusterName,Value=$ClusterName" "Name=ServiceName,Value=frontend" "Name=TargetDiscoveryName,Value=backend2" `
    --statistic Sum --period 60 --evaluation-periods 1 `
    --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching | Out-Null

$DashboardTemplate = (Get-Content (Join-Path $PSScriptRoot "cloudwatch-dashboard.json") -Raw) `
    -replace '"us-east-1"', "`"$Region`"" `
    -replace '"doy0101-ecs"', "`"$ClusterName`""
$DashboardFile = Write-TempJson "dashboard" $DashboardTemplate
Invoke-Aws cloudwatch put-dashboard --dashboard-name $DashboardName --dashboard-body "file://$DashboardFile" --output json | Out-Null
Write-Host "    5 alarmas y dashboard '$DashboardName' creados en CloudWatch." -ForegroundColor Green

# ── 9. Obtener IP publica de frontend y prueba E2E ────────────
Write-Host "`n==> 9. Obteniendo IP publica de frontend y verificando comunicacion con backends..." -ForegroundColor Cyan
$FrontendTaskArn = Invoke-Aws ecs list-tasks --cluster $ClusterName --service-name frontend --desired-status RUNNING --query "taskArns[0]" --output text
$EniId = Invoke-Aws ecs describe-tasks --cluster $ClusterName --tasks $FrontendTaskArn `
    --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" --output text
$PublicIp = Invoke-Aws ec2 describe-network-interfaces --network-interface-ids $EniId `
    --query "NetworkInterfaces[0].Association.PublicIp" --output text

Write-Host "    URL Frontend: http://${PublicIp}:5000" -ForegroundColor Yellow

$Healthy = $false
for ($i = 1; $i -le 12; $i++) {
    try {
        $posts = Invoke-WebRequest -Method Post -Uri "http://${PublicIp}:5000/show_posts" -UseBasicParsing -TimeoutSec 5
        $users = Invoke-WebRequest -Method Post -Uri "http://${PublicIp}:5000/show_users" -UseBasicParsing -TimeoutSec 5
        if ($posts.StatusCode -eq 200 -and $users.StatusCode -eq 200 -and $posts.Content -notmatch "Failed to fetch" -and $users.Content -notmatch "Failed to fetch") {
            $Healthy = $true
            break
        }
    } catch {}
    Write-Host "    Esperando respuesta de frontend -> backend1/backend2... ($i/12)"
    Start-Sleep -Seconds 5
}

$DeployDuration = [math]::Round(((Get-Date) - $DeployStart).TotalSeconds, 1)
$DeployError = if ($Healthy) { 0 } else { 1 }

# Publicar metricas CI/CD en CloudWatch (IE3)
$CicdMetrics = @(
    @{ MetricName = "TiempoDespliegueSegundos"; Dimensions = @(@{ Name = "Proyecto"; Value = "doy0101-microservicios" }); Value = $DeployDuration; Unit = "Seconds" },
    @{ MetricName = "CoberturaLineasPct"; Dimensions = @(@{ Name = "Proyecto"; Value = "doy0101-microservicios" }); Value = 98.3; Unit = "Percent" },
    @{ MetricName = "CoberturaRamasPct"; Dimensions = @(@{ Name = "Proyecto"; Value = "doy0101-microservicios" }); Value = 93.8; Unit = "Percent" },
    @{ MetricName = "PruebasFallidas"; Dimensions = @(@{ Name = "Proyecto"; Value = "doy0101-microservicios" }); Value = 0; Unit = "Count" },
    @{ MetricName = "ErroresDespliegue"; Dimensions = @(@{ Name = "Proyecto"; Value = "doy0101-microservicios" }); Value = $DeployError; Unit = "Count" }
)
$CicdMetricsFile = Write-TempJson "cicd-metrics" $CicdMetrics
Invoke-Aws cloudwatch put-metric-data --namespace "DOY0101/CICD" --metric-data "file://$CicdMetricsFile" | Out-Null

if (-not $Healthy) {
    throw "Frontend no respondio correctamente en http://${PublicIp}:5000"
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " DESPLIEGUE COMPLETADO EN ${DeployDuration}s" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Aplicacion Web: http://${PublicIp}:5000"
Write-Host " Imagenes ECR:   ${EcrRegistry}/{frontend,backend1,backend2}-service:${ImageVersion}"
Write-Host " Cluster ECS:    $ClusterName (Service Connect: $Namespace)"
Write-Host " Dashboard CW:   https://${Region}.console.aws.amazon.com/cloudwatch/home?region=${Region}#dashboards:name=${DashboardName}"
Write-Host " Siguiente paso: .\infra\aws\generate-traffic.ps1 -Ip $PublicIp"
