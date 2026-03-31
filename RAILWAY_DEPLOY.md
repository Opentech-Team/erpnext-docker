# ERPNext on Railway - Opentech Deploy Guide

Fork de [pipech/erpnext-docker-debian](https://github.com/pipech/erpnext-docker-debian) con las siguientes modificaciones:

- ERPNext v16 (en vez de v15)
- Frappe Bench v5.29.0
- Frappe CRM incluido
- Redis con autenticacion (requerido por Railway)
- Setup script corregido para Railway
- Nginx configurado para soportar custom domains

## Arquitectura

```
Railway Project
├── erpnext        (este repo - Dockerfile + nginx + supervisor)
│   ├── gunicorn   (app server, puerto 8000)
│   ├── nginx      (reverse proxy, puerto 80)
│   ├── workers    (background jobs)
│   └── scheduler  (tareas programadas)
├── mariadb        (imagen: mariadb:10.6, con volumen)
├── redis-cache    (Redis plugin de Railway, con auth)
└── redis-queue    (Redis plugin de Railway, con auth)
```

## Prerequisitos

- Cuenta Railway (plan Hobby minimo)
- Railway CLI instalado (`npm install -g @railway/cli`)
- GitHub CLI (`gh`)
- Acceso al repo Opentech-Team/erpnext-docker

## Deploy desde cero (paso a paso)

### 1. Crear proyecto en Railway

```bash
railway login
railway init
# Nombre: erpnext-opentech
# Anotar el project ID que devuelve
```

### 2. Linkear al proyecto

```bash
railway link --project <PROJECT_ID>
```

### 3. Crear servicios de infraestructura

```bash
# Redis (se crean 2 instancias)
railway add -d redis -s redis-cache
railway add -d redis -s redis-queue

# MariaDB (como imagen Docker, NO usar el plugin MySQL de Railway)
railway add -s mariadb -i "mariadb:10.6"
```

**IMPORTANTE:** Railway renombra los Redis automaticamente (ej: "Redis", "Redis-ABC"). Los nombres cosmeticos NO cambian el hostname DNS interno. Hay que obtener los hostnames reales.

### 4. Obtener hostnames y passwords de Redis

```bash
# Redis cache
railway variable list -s redis-cache --json | python3 -c "
import sys,json; data=json.load(sys.stdin)
print('HOST:', data.get('REDISHOST'))
print('PASS:', data.get('REDIS_PASSWORD'))
print('URL:', data.get('REDIS_URL'))
"

# Redis queue
railway variable list -s redis-queue --json | python3 -c "
import sys,json; data=json.load(sys.stdin)
print('HOST:', data.get('REDISHOST'))
print('PASS:', data.get('REDIS_PASSWORD'))
print('URL:', data.get('REDIS_URL'))
"
```

Anotar los REDIS_URL de cada uno. Formato:
`redis://default:<PASSWORD>@<HOST>.railway.internal:6379`

### 5. Configurar MariaDB

```bash
# Crear volumen (via API o dashboard)
# Mount path: /var/lib/mysql

# Variables
railway variable set -s mariadb \
  MARIADB_ROOT_PASSWORD=<TU_PASSWORD_SEGURA> \
  MARIADB_DATABASE=erpnext
```

Start command de MariaDB (configurar via dashboard o API):
```
docker-entrypoint.sh mariadbd --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --skip-character-set-client-handshake --skip-innodb-read-only-compressed
```

### 6. Crear servicio ERPNext desde el repo

```bash
# Via Railway API (el CLI a veces no encuentra repos de orgs)
# O desde el dashboard: New Service > GitHub Repo > Opentech-Team/erpnext-docker
```

Railway auto-detecta el `railway.json` que define:
- Builder: DOCKERFILE
- Dockerfile: `/railway/Dockerfile`
- Start command: `railway-cmd.sh`

### 7. Crear volumen para ERPNext

Mount path: `/home/frappe/bench/sites`

### 8. Configurar variables de ERPNext

```bash
railway variable set -s erpnext \
  RFP_DOMAIN_NAME=<TU_DOMINIO>.up.railway.app \
  RFP_SITE_ADMIN_PASSWORD=<PASSWORD_ADMIN> \
  RFP_DB_ROOT_PASSWORD=<MISMA_PASSWORD_DE_MARIADB> \
  FRAPPE_DB_HOST=mariadb.railway.internal \
  REDIS_CACHE_URL="redis://default:<CACHE_PASS>@<CACHE_HOST>.railway.internal:6379" \
  REDIS_QUEUE_URL="redis://default:<QUEUE_PASS>@<QUEUE_HOST>.railway.internal:6379"
```

**IMPORTANTE:** Las variables `REDIS_CACHE_URL` y `REDIS_QUEUE_URL` son custom (no las default de Railway). El setup script las usa para configurar `common_site_config.json` con autenticacion.

### 9. Generar dominio publico

Desde el dashboard: servicio erpnext > Settings > Networking > Generate Domain.
Configurar target port: **80**

### 10. Esperar el build

El build tarda ~10-15 minutos (compila assets JS, instala dependencias).

### 11. Ejecutar setup del site

Una vez el container este en SUCCESS:

```bash
railway ssh -s erpnext
# Dentro del container:
su frappe -c 'bash /home/frappe/bench/railway-setup.sh'
```

El script automaticamente:
1. Configura Redis con auth en common_site_config.json
2. Crea el site con ERPNext
3. Instala Frappe CRM
4. Habilita el scheduler

### 12. Configurar dominio custom (opcional)

Si quieres usar un dominio propio (ej: `erp.tudominio.com`):

1. En Railway dashboard: servicio erpnext > Settings > Networking > Add Custom Domain
2. Railway te dara un CNAME target (ej: `8s9hdoeb.up.railway.app`)
3. En tu DNS (Cloudflare, etc.), crear registro CNAME:
   - `erp` -> `8s9hdoeb.up.railway.app`
4. **Si usas Cloudflare:** desactivar el proxy (nubecita naranja -> gris, "DNS only") para que Railway pueda validar el CNAME
5. Configurar target port: **80** en el custom domain
6. Agregar el dominio al site de ERPNext:
   ```bash
   railway ssh -s erpnext
   su frappe -c 'cd /home/frappe/bench && bench setup add-domain erp.tudominio.com --site <NOMBRE_DEL_SITE>'
   ```

**NOTA:** No es necesario reiniciar nginx ni gunicorn. El template de nginx (`temp_nginx.conf`) ya esta configurado con `server_name _` (acepta cualquier hostname) y fuerza `X-Frappe-Site-Name` al site principal via la variable `RFP_DOMAIN_NAME`. Esto significa que cualquier dominio que apunte al servicio sera redirigido al site correcto automaticamente.

### 13. Verificar que funciona

Abrir `https://<TU_DOMINIO>.up.railway.app` y logearse con:
- Usuario: `Administrator`
- Password: la que configuraste en `RFP_SITE_ADMIN_PASSWORD`

---

## Gotchas y lecciones aprendidas

> Documentado durante el primer deploy el 2026-03-31.
> Cada uno de estos puntos nos costo tiempo descubrirlo.

### Redis

1. **Redis de Railway requiere autenticacion** - No se puede usar `redis://host:6379` a secas. Hay que incluir `default:<password>@` en la URL. Sin esto, el setup se queda colgado sin error claro.

2. **Los hostnames de Redis NO coinciden con el nombre del servicio** - Railway asigna hostnames internos basados en el nombre original del servicio, no el renombrado via UI o API. Si creas un Redis y Railway lo llama "Redis-9nC0", el hostname sera `redis-9nc0.railway.internal` aunque lo renombres a "redis-queue". Siempre verificar con `railway variable list -s <servicio>` el campo `REDISHOST`.

3. **`FRAPPE_REDIS_*` env vars sobreescriben la config** - Bench/Frappe usa estas env vars por encima de `common_site_config.json`. El setup script hace `unset` de estas para que tome la config con auth. Si no haces esto, Frappe ignora la password de Redis y falla la conexion.

4. **`use_redis_auth: true`** - Obligatorio en `common_site_config.json` cuando Redis tiene password.

### Networking y dominios

5. **Target port del dominio** - Hay que configurar port 80 en el dominio publico (nginx escucha en 80, no en 8000). Sin esto Railway muestra "Application failed to respond".

6. **Frappe resuelve sites por el header Host** - Frappe usa el header `X-Frappe-Site-Name` (que por defecto es `$host`) para determinar que site servir. Si el request llega con `Host: erp.tudominio.com` pero el site se llama `xyz.up.railway.app`, Frappe devuelve 404. La solucion fue configurar nginx para que siempre envie el nombre del site Railway como `X-Frappe-Site-Name`, independientemente del Host real. Esto esta en `temp_nginx.conf`.

7. **Cloudflare proxy bloquea la validacion de Railway** - Si usas Cloudflare con proxy activado (nubecita naranja), Railway no puede verificar el CNAME del custom domain porque Cloudflare intercepta el DNS. Hay que ponerlo en "DNS only" (nubecita gris) para que Railway valide.

### Build y deploy

8. **`railway.json` define el start command** - Si no se pone ahi, Railway puede cachear el start command de deploys anteriores. Nos paso que cambiamos el start command via API pero el container seguia usando `tail -f /dev/null` del deploy original. Ponerlo en `railway.json` lo fuerza.

9. **`bench new-site` necesita `--db-root-username root`** - Sin esto, bench pide input interactivo ("Enter mysql super user [root]:") y el proceso se cuelga.

10. **El CLI de Railway no encuentra repos de organizaciones GitHub** - Aunque Railway tenga acceso via GitHub App, `railway add -r org/repo` puede fallar con "repo not found". La solucion es crear el servicio via la API GraphQL de Railway o desde el dashboard.

11. **Hay que instalar la GitHub App de Railway en la organizacion** - No basta con tenerla en la cuenta personal. Ve a github.com/settings/installations > Railway App > Configure, y dale acceso a la org.

### Setup del site

12. **`currentsite.txt` debe existir** - Frappe necesita este archivo en `/home/frappe/bench/sites/` para saber cual es el site por defecto. Si no existe, muchos comandos de bench fallan silenciosamente.

13. **El setup tarda y puede parecer colgado** - `bench new-site` con `--install-app erpnext` tarda 5-10 minutos sin mostrar output. No cancelar. Si se ejecuta por SSH no interactivo, el timeout puede matar el proceso.

---

## Actualizaciones

Para actualizar ERPNext, cambiar el tag en `railway/Dockerfile`:
```dockerfile
FROM pipech/erpnext-docker-debian:version-16-latest AS builder
```

El repo upstream (pipech) publica imagenes nuevas cada domingo.

---

## Credenciales (deploy actual - 2026-03-31)

- **URL principal:** https://erpnext-production-a951.up.railway.app
- **URL custom:** https://erp.lccopen.tech
- **Admin:** Administrator / OpentechAdmin2026!
- **MariaDB root:** OpentechERP2026!
- **Railway Project ID:** 0195f865-c8a5-47ae-9d24-1f4a58b38f8a
