#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Enterprise Kubernetes Lab Bootstrap
# k3d + PostgreSQL 15 + Odoo 17 + kube-prometheus-stack
#
# Troubleshooting fixes built in:
#   - PostgreSQL DB creation is separate from Odoo schema initialization.
#   - Odoo schema initialization runs as a dedicated Kubernetes Job.
#   - The init Job has explicit resources so ResourceQuota admits it.
#   - A LimitRange gives ad-hoc pods default resources.
#   - Odoo DB initialization is idempotent and skipped when already complete.
#   - Odoo is deployed only after DB initialization succeeds.
#   - Startup/readiness/liveness probes have separate responsibilities.
# ==============================================================================

CLUSTER_NAME="${CLUSTER_NAME:-enterprise-lab}"
K3D_NETWORK="${K3D_NETWORK:-k3d-lab-net}"
DOCKER_MTU="${DOCKER_MTU:-1400}"
K3D_SERVERS="${K3D_SERVERS:-1}"
K3D_AGENTS="${K3D_AGENTS:-2}"

DB_NAMESPACE="${DB_NAMESPACE:-database}"
APP_NAMESPACE="${APP_NAMESPACE:-apps}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

DB_USER="${DB_USER:-odoo_user}"
DB_NAME="${DB_NAME:-odoo}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:15-alpine}"
ODOO_IMAGE="${ODOO_IMAGE:-odoo:17.0}"
POSTGRES_STORAGE="${POSTGRES_STORAGE:-5Gi}"
ODOO_STORAGE="${ODOO_STORAGE:-5Gi}"

ODOO_HOST="${ODOO_HOST:-odoo.localhost}"
GRAFANA_HOST="${GRAFANA_HOST:-grafana.localhost}"
PROMETHEUS_HOST="${PROMETHEUS_HOST:-prometheus.localhost}"

RESET_CLUSTER="${RESET_CLUSTER:-false}"
INSTALL_MONITORING="${INSTALL_MONITORING:-true}"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-unknown}
  printf '\n\033[1;31m[ERROR]\033[0m Script failed near line %s (exit code %s).\n' "$line_no" "$exit_code" >&2
  exit "$exit_code"
}
trap on_error ERR

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

random_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 18
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36
  fi
}

cluster_exists() {
  k3d cluster list -o json 2>/dev/null | \
    grep -Eq "\"name\"[[:space:]]*:[[:space:]]*\"${CLUSTER_NAME}\""
}

wait_for_postgres() {
  log "Waiting for PostgreSQL deployment"
  kubectl -n "$DB_NAMESPACE" rollout status deployment/enterprise-postgres --timeout=5m

  log "Checking PostgreSQL readiness"
  local tries=0
  until kubectl -n "$DB_NAMESPACE" exec deployment/enterprise-postgres -- \
      pg_isready -U "$DB_USER" -d postgres >/dev/null 2>&1; do
    tries=$((tries + 1))
    if (( tries >= 60 )); then
      kubectl -n "$DB_NAMESPACE" get pods -o wide || true
      kubectl -n "$DB_NAMESPACE" logs deployment/enterprise-postgres --tail=100 || true
      die "PostgreSQL did not become ready."
    fi
    sleep 5
  done
  ok "PostgreSQL is accepting connections."
}

ensure_odoo_database() {
  log "Ensuring PostgreSQL database '$DB_NAME' exists"
  local exists
  exists="$(
    kubectl -n "$DB_NAMESPACE" exec deployment/enterprise-postgres -- \
      psql -U "$DB_USER" -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';" | tr -d '[:space:]'
  )"

  if [[ "$exists" == "1" ]]; then
    ok "Database '$DB_NAME' already exists."
  else
    kubectl -n "$DB_NAMESPACE" exec deployment/enterprise-postgres -- \
      createdb -U "$DB_USER" -O "$DB_USER" "$DB_NAME"
    ok "Database '$DB_NAME' created."
  fi
}

odoo_is_initialized() {
  local table_exists
  table_exists="$(
    kubectl -n "$DB_NAMESPACE" exec deployment/enterprise-postgres -- \
      psql -U "$DB_USER" -d "$DB_NAME" -tAc \
      "SELECT to_regclass('public.ir_module_module') IS NOT NULL;" | tr -d '[:space:]'
  )"
  [[ "$table_exists" == "t" ]] || return 1

  local base_state
  base_state="$(
    kubectl -n "$DB_NAMESPACE" exec deployment/enterprise-postgres -- \
      psql -U "$DB_USER" -d "$DB_NAME" -tAc \
      "SELECT state FROM ir_module_module WHERE name='base' LIMIT 1;" | tr -d '[:space:]'
  )"
  [[ "$base_state" == "installed" ]]
}

run_odoo_init_job() {
  log "Initializing Odoo database schema"
  kubectl -n "$APP_NAMESPACE" delete job odoo-db-init --ignore-not-found >/dev/null

  cat <<YAML | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: odoo-db-init
  namespace: ${APP_NAMESPACE}
  labels:
    app: odoo-db-init
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: odoo-db-init
    spec:
      restartPolicy: Never
      containers:
        - name: odoo-init
          image: ${ODOO_IMAGE}
          imagePullPolicy: IfNotPresent
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "1Gi"
          env:
            - name: HOST
              value: enterprise-postgres.${DB_NAMESPACE}.svc.cluster.local
            - name: PORT
              value: "5432"
            - name: USER
              valueFrom:
                secretKeyRef:
                  name: odoo-db-credentials
                  key: DB_USER
            - name: PASSWORD
              valueFrom:
                secretKeyRef:
                  name: odoo-db-credentials
                  key: DB_PASSWORD
          volumeMounts:
            - name: odoo-data
              mountPath: /var/lib/odoo
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -Eeuo pipefail
              echo "Starting Odoo database initialization"
              echo "Database host: \$HOST"
              echo "Database port: \$PORT"
              echo "Database user: \$USER"
              echo "Database name: ${DB_NAME}"

              odoo \\
                --db_host="\$HOST" \\
                --db_port="\$PORT" \\
                --db_user="\$USER" \\
                --db_password="\$PASSWORD" \\
                --database="${DB_NAME}" \\
                --init=base \\
                --without-demo=all \\
                --stop-after-init

              echo "Odoo database initialization completed"
      volumes:
        - name: odoo-data
          persistentVolumeClaim:
            claimName: odoo-data
YAML

log "Waiting for Odoo initialization Job to complete. Fresh image pulls may take several minutes..."

if ! kubectl -n "$APP_NAMESPACE" wait --for=condition=complete job/odoo-db-init --timeout=30m; then
    warn "Odoo initialization Job did not complete successfully."
    kubectl -n "$APP_NAMESPACE" get job odoo-db-init -o wide || true
    kubectl -n "$APP_NAMESPACE" get pods -l job-name=odoo-db-init -o wide || true
    kubectl -n "$APP_NAMESPACE" describe job odoo-db-init || true
    kubectl -n "$APP_NAMESPACE" describe pod -l job-name=odoo-db-init || true
    kubectl -n "$APP_NAMESPACE" logs -l job-name=odoo-db-init --tail=250 || true
    die "Odoo database initialization failed."
fi

  kubectl -n "$APP_NAMESPACE" logs job/odoo-db-init --tail=80 || true
  odoo_is_initialized || die "Odoo Job completed, but database verification failed."
  ok "Odoo database schema is initialized and base is installed."
}

log "Checking prerequisites"
for cmd in docker k3d kubectl helm; do require_cmd "$cmd"; done
docker info >/dev/null 2>&1 || die "Docker is not running or accessible."
ok "Required commands are available."

log "Ensuring Docker network '$K3D_NETWORK' exists"
if docker network inspect "$K3D_NETWORK" >/dev/null 2>&1; then
  ok "Docker network '$K3D_NETWORK' already exists."
else
  docker network create --driver bridge \
    --opt "com.docker.network.driver.mtu=${DOCKER_MTU}" \
    "$K3D_NETWORK" >/dev/null
  ok "Docker network '$K3D_NETWORK' created with MTU ${DOCKER_MTU}."
fi

if [[ "$RESET_CLUSTER" == "true" ]] && cluster_exists; then
  log "Deleting existing cluster because RESET_CLUSTER=true"
  k3d cluster delete "$CLUSTER_NAME"
fi

if cluster_exists; then
  log "Using existing k3d cluster '$CLUSTER_NAME'"
else
  log "Creating k3d cluster '$CLUSTER_NAME'"
  k3d cluster create "$CLUSTER_NAME" \
    --servers "$K3D_SERVERS" \
    --agents "$K3D_AGENTS" \
    --network "$K3D_NETWORK" \
    -p "80:80@loadbalancer" \
    -p "443:443@loadbalancer" \
    --wait
fi

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=5m
ok "All cluster nodes are Ready."

log "Creating namespaces"
for ns in "$DB_NAMESPACE" "$APP_NAMESPACE" "$MONITORING_NAMESPACE"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
ok "Namespaces are present."

log "Applying apps ResourceQuota and LimitRange"
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: apps-quota
  namespace: ${APP_NAMESPACE}
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 2Gi
    limits.cpu: "2"
    limits.memory: 4Gi
---
apiVersion: v1
kind: LimitRange
metadata:
  name: apps-default-resources
  namespace: ${APP_NAMESPACE}
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: "50m"
        memory: "64Mi"
      default:
        cpu: "250m"
        memory: "256Mi"
YAML
ok "Quota and default resources configured."

if [[ -z "${DB_PASSWORD:-}" ]]; then
  if kubectl -n "$DB_NAMESPACE" get secret postgres-credentials >/dev/null 2>&1; then
    DB_PASSWORD="$(kubectl -n "$DB_NAMESPACE" get secret postgres-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
  else
    DB_PASSWORD="$(random_password)"
  fi
fi

log "Applying database credentials"
kubectl -n "$DB_NAMESPACE" create secret generic postgres-credentials \
  --from-literal=POSTGRES_USER="$DB_USER" \
  --from-literal=POSTGRES_PASSWORD="$DB_PASSWORD" \
  --from-literal=POSTGRES_DB="postgres" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$APP_NAMESPACE" create secret generic odoo-db-credentials \
  --from-literal=DB_USER="$DB_USER" \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "Database credentials synchronized across namespaces."

log "Deploying PostgreSQL"
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: ${DB_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: ${POSTGRES_STORAGE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: enterprise-postgres
  namespace: ${DB_NAMESPACE}
  labels:
    app: enterprise-postgres
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: enterprise-postgres
  template:
    metadata:
      labels:
        app: enterprise-postgres
    spec:
      containers:
        - name: postgres
          image: ${POSTGRES_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - name: postgres
              containerPort: 5432
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_USER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_PASSWORD
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_DB
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          resources:
            requests:
              cpu: "200m"
              memory: "256Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
          readinessProbe:
            exec:
              command: ["/bin/sh", "-c", "pg_isready -U \"\$POSTGRES_USER\" -d postgres"]
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 5
            failureThreshold: 12
          livenessProbe:
            exec:
              command: ["/bin/sh", "-c", "pg_isready -U \"\$POSTGRES_USER\" -d postgres"]
            initialDelaySeconds: 30
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 6
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: postgres-data
          persistentVolumeClaim:
            claimName: postgres-data
---
apiVersion: v1
kind: Service
metadata:
  name: enterprise-postgres
  namespace: ${DB_NAMESPACE}
spec:
  selector:
    app: enterprise-postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
  type: ClusterIP
YAML

wait_for_postgres
ensure_odoo_database

log "Ensuring Odoo persistent storage exists"
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odoo-data
  namespace: ${APP_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: ${ODOO_STORAGE}
YAML

log "Checking Odoo database initialization state"
if odoo_is_initialized; then
  ok "Odoo database already initialized; skipping init Job."
else
  run_odoo_init_job
fi

ODOO_TABLE_COUNT="$(kubectl -n "$DB_NAMESPACE" exec deployment/enterprise-postgres -- \
  psql -U "$DB_USER" -d "$DB_NAME" -tAc \
  "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='public';" | tr -d '[:space:]')"
ok "Odoo database contains ${ODOO_TABLE_COUNT} public tables."

log "Deploying Odoo"
cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: odoo-app
  namespace: ${APP_NAMESPACE}
  labels:
    app: odoo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: odoo
  template:
    metadata:
      labels:
        app: odoo
    spec:
      containers:
        - name: odoo
          image: ${ODOO_IMAGE}
          imagePullPolicy: IfNotPresent
          args:
            - --database=${DB_NAME}
          ports:
            - name: http
              containerPort: 8069
          env:
            - name: HOST
              value: enterprise-postgres.${DB_NAMESPACE}.svc.cluster.local
            - name: PORT
              value: "5432"
            - name: USER
              valueFrom:
                secretKeyRef:
                  name: odoo-db-credentials
                  key: DB_USER
            - name: PASSWORD
              valueFrom:
                secretKeyRef:
                  name: odoo-db-credentials
                  key: DB_PASSWORD
          resources:
            requests:
              cpu: "300m"
              memory: "512Mi"
            limits:
              cpu: "1"
              memory: "1536Mi"
          startupProbe:
            httpGet:
              path: /web/login
              port: 8069
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /web/login
              port: 8069
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          livenessProbe:
            tcpSocket:
              port: 8069
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 3
          volumeMounts:
            - name: odoo-data
              mountPath: /var/lib/odoo
      volumes:
        - name: odoo-data
          persistentVolumeClaim:
            claimName: odoo-data
---
apiVersion: v1
kind: Service
metadata:
  name: odoo-service
  namespace: ${APP_NAMESPACE}
spec:
  selector:
    app: odoo
  ports:
    - name: http
      port: 8069
      targetPort: 8069
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: odoo
  namespace: ${APP_NAMESPACE}
spec:
  ingressClassName: traefik
  rules:
    - host: ${ODOO_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: odoo-service
                port:
                  number: 8069
YAML

if ! kubectl -n "$APP_NAMESPACE" rollout status deployment/odoo-app --timeout=8m; then
  kubectl -n "$APP_NAMESPACE" get pods -o wide || true
  kubectl -n "$APP_NAMESPACE" describe pod -l app=odoo || true
  kubectl -n "$APP_NAMESPACE" logs deployment/odoo-app --tail=250 || true
  die "Odoo deployment did not become available."
fi
ok "Odoo deployment is available."

log "Running Odoo HTTP smoke test"
HTTP_STATUS="$(kubectl -n "$APP_NAMESPACE" exec deployment/odoo-app -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8069/web/login', timeout=10).status)")"
[[ "$HTTP_STATUS" == "200" ]] || die "Odoo smoke test returned HTTP ${HTTP_STATUS}, expected 200."
ok "Odoo /web/login returned HTTP 200."

if [[ "$INSTALL_MONITORING" == "true" ]]; then
  log "Installing/upgrading kube-prometheus-stack"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
  helm repo update >/dev/null

  if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    if kubectl -n "$MONITORING_NAMESPACE" get secret monitoring-grafana >/dev/null 2>&1; then
      GRAFANA_ADMIN_PASSWORD="$(kubectl -n "$MONITORING_NAMESPACE" get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
    else
      GRAFANA_ADMIN_PASSWORD="$(random_password)"
    fi
  fi

  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --namespace "$MONITORING_NAMESPACE" \
    --create-namespace \
    --set-string grafana.adminPassword="$GRAFANA_ADMIN_PASSWORD" \
    --set grafana.ingress.enabled=true \
    --set-string grafana.ingress.ingressClassName=traefik \
    --set-string "grafana.ingress.hosts[0]=${GRAFANA_HOST}" \
    --set prometheus.ingress.enabled=true \
    --set-string prometheus.ingress.ingressClassName=traefik \
    --set-string "prometheus.ingress.hosts[0]=${PROMETHEUS_HOST}" \
    --wait --timeout 30m
  ok "Monitoring stack installed."
else
  warn "INSTALL_MONITORING=false; monitoring installation skipped."
  GRAFANA_ADMIN_PASSWORD="<not-installed>"
fi

log "Final status"
kubectl get nodes
echo
kubectl -n "$DB_NAMESPACE" get deploy,pod,svc,pvc
echo
kubectl -n "$APP_NAMESPACE" get deploy,pod,svc,ingress,pvc,job
if [[ "$INSTALL_MONITORING" == "true" ]]; then
  echo
  kubectl -n "$MONITORING_NAMESPACE" get pods
fi

cat <<SUMMARY

==============================================================================
Enterprise Lab is ready
==============================================================================

Odoo:
  URL:        http://${ODOO_HOST}
  Database:   ${DB_NAME}
  DB user:    ${DB_USER}

Grafana:
  URL:        http://${GRAFANA_HOST}
  Username:   admin
  Password:   ${GRAFANA_ADMIN_PASSWORD}

Prometheus:
  URL:        http://${PROMETHEUS_HOST}

Useful commands:
  kubectl -n ${APP_NAMESPACE} get pods
  kubectl -n ${APP_NAMESPACE} logs deployment/odoo-app --tail=100
  kubectl -n ${DB_NAMESPACE} logs deployment/enterprise-postgres --tail=100
  kubectl -n ${APP_NAMESPACE} get events --sort-by='.lastTimestamp' | tail -30

Re-run safely:
  ./lab_up.sh

Fresh rebuild:
  RESET_CLUSTER=true ./lab_up.sh

Skip monitoring:
  INSTALL_MONITORING=false ./lab_up.sh

==============================================================================
SUMMARY
