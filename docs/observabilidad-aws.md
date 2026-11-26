# Observabilidad, Orquestación y Despliegue Versionado en AWS (EP3 / Actividad 3.2)

Este documento describe la arquitectura **100 % AWS** implementada para la **Evaluación Parcial N°3 de Ingeniería DevOps (DOY0101, Duoc UC)** sobre los tres microservicios del encargo (`frontend`, `backend1` y `backend2`), cubriendo **IE1, IE2, IE3 e IE4** sin depender de herramientas externas fuera de AWS.

---

## 1. Arquitectura en AWS

```
                         Internet (TCP 5000)
                                 │
                                 ▼
              ┌─────────────────────────────────────┐
              │  doy0101-microservicios-sg (VPC default)    │
              │  • TCP 5000      <- 0.0.0.0/0       │
              │  • TCP 5001-5002 <- CIDR de la VPC  │
              └──────────────────┬──────────────────┘
                                 │
   ┌─────────────────────────────▼─────────────────────────────┐
   │  Amazon ECS Fargate — Clúster: doy0101-ecs                │
   │  Container Insights (enhanced) + Service Connect          │
   │  Namespace AWS Cloud Map: microservices-demo              │
   │                                                           │
   │                    ┌─────────────────┐                    │
   │                    │ frontend :5000  │                    │
   │                    │ (ECR :1.0.0)    │                    │
   │                    │ Solo Cliente    │                    │
   │                    └───┬─────────┬───┘                    │
   │        HTTP (Envoy SC) │         │ HTTP (Envoy SC)        │
   │   backend1-service:5001│         │ backend2-service:5002  │
   │                        ▼         ▼                        │
   │           ┌─────────────────┐ ┌─────────────────┐         │
   │           │ backend1 :5001  │ │ backend2 :5002  │         │
   │           │ /posts (ECR)    │ │ /users (ECR)    │         │
   │           │ Cliente/Servidor│ │ Cliente/Servidor│         │
   │           └────────┬────────┘ └────────┬────────┘         │
   └────────────────────┼───────────────────┼──────────────────┘
                        │ logs + métricas   │
                        ▼                   ▼
   ┌───────────────────────────────────────────────────────────┐
   │  Amazon CloudWatch                                        │
   │  • Log Groups: /ecs/frontend, /ecs/backend1, /ecs/backend2│
   │  • Metric Filters: 404 y ERROR/500 (DOY0101/AppLogs)      │
   │  • Container Insights: CPU, Memoria, Tareas, Red          │
   │  • Service Connect: RequestCount, Latency, 2xx/4xx/5xx    │
   │  • Métricas CI/CD (DOY0101/CICD): Cobertura, Duración     │
   │  • Alarmas (5) + Dashboard doy0101-microservicios-Tapia   │
   └───────────────────────────────────────────────────────────┘
```

### Principio de mínimo privilegio en red
- El único puerto expuesto a Internet (`0.0.0.0/0`) es **TCP 5000** (`frontend`).
- Los puertos **5001 y 5002** (`backend1` y `backend2`) solo aceptan tráfico desde el **CIDR de la VPC**, impidiendo que clientes externos consuman directamente los backends sin pasar por `frontend` ni por el sidecar Envoy de Service Connect.

---

## 2. Imágenes versionadas en Amazon ECR (mejora sobre EP2)

En la Evaluación Parcial 2 el workflow de CD reconstruía la imagen Docker en el propio runner durante el despliegue. Para garantizar inmutabilidad, trazabilidad y rollbacks rápidos, ahora el despliegue consume **imágenes versionadas desde Amazon ECR**:
- Repositorios privados en ECR (`us-east-1`): `frontend-service`, `backend1-service` y `backend2-service` (con `scanOnPush=true` y política de ciclo de vida que conserva las últimas 10 versiones).
- Etiquetado versionado: `1.0.0` (y `latest`), espejadas desde las imágenes base entregadas por el docente (`guillermovillacuratorres/{frontend,backend1,backend2}-service:latest`).
- **CD (`.github/workflows/cd-deploy.yml`)** **no reconstruye** en el runner: verifica la existencia del tag versionado en Amazon ECR, registra nuevas revisiones de las Task Definitions en ECS (`backend1` y `backend2` primero, luego `frontend`), espera `services-stable`, valida `/show_posts` y `/show_users` y registra el tiempo de despliegue en CloudWatch.

---

## 3. Integración con el pipeline CI/CD y métricas en CloudWatch

| Etapa | Servicio AWS | Qué registra automáticamente |
|---|---|---|
| **CI (`ci.yml`)** | CloudWatch Metrics (`DOY0101/CICD`) | `CoberturaLineasPct`, `CoberturaRamasPct` (JaCoCo) y `PruebasFallidas` (Surefire). |
| **CD (`cd-deploy.yml`)** | Amazon ECR + Amazon ECS | Despliega las imágenes versionadas (`1.0.0`) sin reconstruirlas en el runner, en orden `backend1`/`backend2` → `frontend`. |
| **CD (`cd-deploy.yml`)** | CloudWatch Metrics (`DOY0101/CICD`) | `TiempoDespliegueSegundos` y `ErroresDespliegue`. |
| **Runtime (ECS)** | CloudWatch Container Insights | `CpuUtilized`, `MemoryUtilized`, `RunningTaskCount`, `DesiredTaskCount`, `NetworkRxBytes`, `NetworkTxBytes` de los 3 servicios. |
| **Runtime (Service Connect)** | CloudWatch Metrics (`AWS/ECS`) | `RequestCount` (servidor y cliente `frontend -> backends`), `TargetResponseTime` (promedio y p99), `HTTPCode_Target_2XX/4XX/5XX_Count`, `ActiveConnectionCount`, `NewConnectionCount`. |
| **Runtime (Logs)** | CloudWatch Logs + Metric Filters | Logs centralizados en `/ecs/frontend`, `/ecs/backend1`, `/ecs/backend2` (retención 14 días) y contadores `Frontend404Count` / `BackendErrorCount` (`DOY0101/AppLogs`). |

---

## 4. Alarmas configuradas en CloudWatch (IE1)

| Alarma | Métrica | Condición | Propósito operativo |
|---|---|---|---|
| `doy0101-frontend-disponibilidad` | `RunningTaskCount` (`frontend`) | `< 1` en 1 min | Detectar caída del punto de entrada web. |
| `doy0101-backend1-disponibilidad` | `RunningTaskCount` (`backend1`) | `< 1` en 1 min | Detectar caída del servicio `/posts`. |
| `doy0101-backend2-disponibilidad` | `RunningTaskCount` (`backend2`) | `< 1` en 1 min | Detectar caída del servicio `/users`. |
| `doy0101-backend1-errores-5xx` | `HTTPCode_Target_5XX_Count` (`backend1`) | `>= 1` en 1 min | Detectar fallos internos HTTP 5xx en `backend1`. |
| `doy0101-backend2-errores-5xx` | `HTTPCode_Target_5XX_Count` (`backend2`) | `>= 1` en 1 min | Detectar fallos internos HTTP 5xx en `backend2`. |

---

## 5. Toma de decisiones técnicas a partir del Dashboard (IE4)

El dashboard `doy0101-microservicios-Tapia` (definido como código en [`infra/aws/cloudwatch-dashboard.json`](../infra/aws/cloudwatch-dashboard.json)) unifica los widgets W1–W8 de la Actividad 3.2 con las métricas del pipeline CI/CD (W9), Metric Filters de logs (W10) y CloudWatch Logs Insights (W11):

| Señal en el Dashboard | Diagnóstico técnico | Decisión / acción de mejora continua |
|---|---|---|
| `RunningTaskCount < DesiredTaskCount` (W2) | Contenedor detenido por fallo de arranque, OOM o intervención manual. | Revisar `/ecs/<servicio>` en W11; si ocurrió tras un despliegue, ejecutar `cd-deploy.yml` indicando la `image_version` anterior de ECR (rollback). |
| `CpuUtilized` o `MemoryUtilized` sostenidamente altos (W1) | El servicio se acerca al límite de 0.25 vCPU / 0.5 GB. | Aumentar `desired-count` (escalado horizontal detrás de Service Connect) o subir CPU/memoria en la Task Definition. |
| `TargetResponseTime` p99 crece respecto al promedio (W5) | Colas o lentitud intermitente en uno de los backends. | Aislar qué backend (`backend1` vs `backend2`) presenta la cola larga, revisar sus logs y escalar solo ese servicio. |
| Aumento de `HTTPCode_Target_4XX_Count` (W6) o `Frontend404Count` (W10) | Rutas inexistentes o errores de cliente. | Inspeccionar las rutas en W11 (`/ecs/frontend`) para detectar integraciones rotas o escaneos. |
| Aparición de `HTTPCode_Target_5XX_Count` (W6) o `BackendErrorCount` (W10) | Error interno en `backend1` o `backend2`. | Revisar alarma y stacktrace en CloudWatch Logs; corregir vía `hotfix/*` con prueba de regresión. |
| `RequestCount` cliente (`frontend -> backend2`, W7) sin correlato en servidor (`backend2`, W4) | El backend destino está caído o inalcanzable por red/DNS. | Verificar estado de tareas en W2, reglas de `doy0101-microservicios-sg` (5001-5002) y estado de Envoy Service Connect. |
| `TiempoDespliegueSegundos` al alza o `CoberturaLineasPct` a la baja (W9) | Degradación en velocidad de entrega o cobertura de pruebas. | Optimizar el flujo de despliegue y reforzar pruebas antes de incumplir los umbrales de JaCoCo (90 % / 80 %). |

---

## 6. Operación en un nuevo laboratorio AWS Academy

Con las credenciales activas del Learner Lab en `~/.aws/credentials`:

```powershell
# 1. Aprovisionar ECR (imagenes versionadas), ECS Fargate + Service Connect, Alarmas y Dashboard
.\infra\aws\provision-ecs.ps1

# 2. Generar trafico HTTP real (/show_posts, /show_users y 404 controlados)
.\infra\aws\generate-traffic.ps1 -Ip <IP-PUBLICA-FRONTEND>

# 3. Al terminar y capturar evidencias, limpiar todos los recursos
.\infra\aws\cleanup-ecs.ps1
```
