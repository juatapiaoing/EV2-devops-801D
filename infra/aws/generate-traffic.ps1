# ============================================================
# Generador de trafico contra frontend:5000 en Amazon ECS
# (Actividad 3.2 - Parte 5 / EP3)
# ============================================================
# Envia peticiones POST a /show_posts y /show_users + errores 404
# controlados para poblar Container Insights y Service Connect.
#
# Uso:
#   .\infra\aws\generate-traffic.ps1 -Ip <IP-PUBLICA-FRONTEND>
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Ip,
    [int]$Iterations = 300,
    [int]$ErrorRequests = 40
)

Write-Host "==> Generando trafico hacia http://${Ip}:5000 ($Iterations peticiones a posts/users + $ErrorRequests errores 404)..." -ForegroundColor Cyan

1..$Iterations | ForEach-Object {
    curl.exe -s -o NUL -X POST "http://${Ip}:5000/show_posts"
    curl.exe -s -o NUL -X POST "http://${Ip}:5000/show_users"
    if ($_ % 25 -eq 0) {
        Write-Host "    Peticion $_ / $Iterations enviada"
    }
}

Write-Host "==> Enviando $ErrorRequests errores 404 controlados (/no-existe)..." -ForegroundColor Yellow
1..$ErrorRequests | ForEach-Object {
    curl.exe -s -o NUL "http://${Ip}:5000/no-existe"
}

Write-Host "==> Trafico finalizado. Espere 1-2 min para Service Connect y ~5 min para Container Insights en CloudWatch." -ForegroundColor Green
