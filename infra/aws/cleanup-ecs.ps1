# ============================================================
# Limpieza de recursos AWS (ECS, ECR, CloudWatch, Cloud Map, SG)
# ============================================================
# Elimina los recursos creados por provision-ecs.ps1 para evitar
# consumo innecesario de credito en AWS Academy Learner Lab.
#
# Uso:
#   .\infra\aws\cleanup-ecs.ps1
# ============================================================
param(
    [string]$Region = "us-east-1",
    [string]$ClusterName = "doy0101-ecs",
    [string]$Namespace = "microservices-demo",
    [string]$DashboardName = "doy0101-microservicios-Tapia"
)

$ErrorActionPreference = "Continue"
$UvAwsPy = Join-Path $env:APPDATA "uv\tools\awscli\Scripts\python.exe"

function Invoke-AwsSafe {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CliArgs)
    if (Test-Path $UvAwsPy) {
        & $UvAwsPy -m awscli --region $Region @CliArgs 2>$null
    } else {
        & aws --region $Region @CliArgs 2>$null
    }
}

Write-Host "==> 1. Escalando a 0 y eliminando servicios ECS..." -ForegroundColor Cyan
foreach ($svc in @("frontend", "backend1", "backend2")) {
    Invoke-AwsSafe ecs update-service --cluster $ClusterName --service $svc --desired-count 0 | Out-Null
    Invoke-AwsSafe ecs delete-service --cluster $ClusterName --service $svc --force | Out-Null
    Write-Host "    Servicio '$svc' eliminado."
}

Write-Host "==> 2. Esperando drenado de tareas y eliminando cluster '$ClusterName'..." -ForegroundColor Cyan
Start-Sleep -Seconds 15
Invoke-AwsSafe ecs delete-cluster --cluster $ClusterName | Out-Null

Write-Host "==> 3. Eliminando Dashboard, Alarmas y Log Groups de CloudWatch..." -ForegroundColor Cyan
Invoke-AwsSafe cloudwatch delete-dashboards --dashboard-names $DashboardName | Out-Null
Invoke-AwsSafe cloudwatch delete-alarms --alarm-names `
    "doy0101-frontend-disponibilidad" `
    "doy0101-backend1-disponibilidad" `
    "doy0101-backend2-disponibilidad" `
    "doy0101-backend1-errores-5xx" `
    "doy0101-backend2-errores-5xx" | Out-Null

foreach ($lg in @("/ecs/frontend", "/ecs/backend1", "/ecs/backend2")) {
    Invoke-AwsSafe logs delete-log-group --log-group-name $lg | Out-Null
}

Write-Host "==> 4. Eliminando repositorios Amazon ECR..." -ForegroundColor Cyan
foreach ($repo in @("frontend-service", "backend1-service", "backend2-service")) {
    Invoke-AwsSafe ecr delete-repository --repository-name $repo --force | Out-Null
}

Write-Host "==> 5. Eliminando namespace Cloud Map '$Namespace'..." -ForegroundColor Cyan
$nsId = (Invoke-AwsSafe servicediscovery list-namespaces --output json | ConvertFrom-Json).Namespaces |
    Where-Object { $_.Name -eq $Namespace } | Select-Object -ExpandProperty Id
if ($nsId) {
    $services = (Invoke-AwsSafe servicediscovery list-services --filters "Name=NAMESPACE_ID,Values=$nsId,Condition=EQ" --output json | ConvertFrom-Json).Services
    foreach ($s in $services) {
        Invoke-AwsSafe servicediscovery delete-service --id $s.Id | Out-Null
    }
    Invoke-AwsSafe servicediscovery delete-namespace --id $nsId | Out-Null
}

Write-Host "==> 6. Eliminando Security Group doy0101-microservicios-sg..." -ForegroundColor Cyan
$sgId = Invoke-AwsSafe ec2 describe-security-groups --filters "Name=group-name,Values=doy0101-microservicios-sg" --query "SecurityGroups[0].GroupId" --output text
if ($sgId -and $sgId -ne "None") {
    Invoke-AwsSafe ec2 delete-security-group --group-id $sgId | Out-Null
}

Write-Host "==> Limpieza completada." -ForegroundColor Green
