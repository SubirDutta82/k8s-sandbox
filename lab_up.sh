#!/bin/bash
#
# lab-up.sh — Spin up a production-shaped Kubernetes sandbox for demos/recording.
# Uses k3d (Docker-based k3s clusters).
# Idempotent: safe to re-run.
#

set -euo pipefail

# ---------- Config ----------
CLUSTER_NAME="enterprise-lab"
APP_MANIFEST="odoo-multi-ns.yaml"
INGRESS_MANIFEST="ingress.yaml"
MONITORING_NS="monitoring"
LAB_NETWORK="k3d-lab-net"
LOG_FILE="lab-up.log"

# Track whether the caller explicitly exported a password before we default it.
PASSWORD_WAS_EXPLICIT=true
if [ -z "${POSTGRES_PASSWORD:-}" ]; then
  PASSWORD_WAS_EXPLICIT=false
fi
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -base64 18)}"

# ---------- Helpers ----------
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

fail() {
  log "ERROR: $*"
  exit 1
}

retry_cmd() {
  local attempts="$1"
  local delay="$2"
  shift 2

  local n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      fail "Command failed after $attempts attempts: $*"
    fi

    log "Attempt $n/$attempts failed. Retrying in ${delay}s..."
    n=$((n + 1))
    sleep "$delay"
  done
}

run_with_heartbeat() {
  local desc="$1"
  local watch_ns="$2"
  shift 2

  log "Starting: ${desc}..."
  "$@" &
  local cmd_pid=$!
  local elapsed=0
  local interval=15

  while kill -0 "$cmd_pid" 2>/dev/null; do
    sleep "$interval"
    elapsed=$((elapsed + interval))

    if ! kill -0 "$cmd_pid" 2>/dev/null; then
      break
    fi

    if [ -n "$watch_ns" ]; then
      local snapshot
      snapshot="$(kubectl get pods -n "$watch_ns" --no-headers 2>/dev/null \
        | awk '{printf "%s:%s  ", $1, $2}')"
      log "(${elapsed}s elapsed) ${desc} — pods: ${snapshot:-not created yet}"
    else
      log "(${elapsed}s elapsed) ${desc}..."
    fi
  done

  local status=0
  wait "$cmd_pid" || status=$?

  if [ "$status" -ne 0 ]; then
    fail "${desc} failed after ${elapsed}s (exit code ${status})"
  fi

  log "${desc} completed in ${elapsed}s"
}

trap 'log "Script failed at line $LINENO. See $LOG_FILE for details."' ERR

# ---------- Checks ----------
check_deps() {
  log "Checking required tools..."

  local missing=()
  for bin in k3d kubectl helm docker openssl; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    fail "Missing required tools: ${missing[*]}. Install them before running this script."
  fi

  docker info >/dev/null 2>&1 || \
    fail "Docker daemon isn't reachable. Is Docker/WSL2 integration running?"
}

check_resources() {
  log "Checking Docker/WSL2 resource allocation..."

  local mem_bytes cpus
  mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"

  local mem_gb=$((mem_bytes / 1024 / 1024 / 1024))

  if [ "$mem_gb" -gt 0 ] && [ "$mem_gb" -lt 6 ]; then
    log "WARNING: Docker/WSL2 has only ~${mem_gb}GB memory allocated."
    log "WARNING: Postgres + Odoo + monitoring may put heavy pressure on the lab."
    log "WARNING: Consider raising WSL2 memory to 6-8GB+ if you see restarts or commit errors."
  fi

  if [ "$cpus" -gt 0 ] && [ "$cpus" -lt 4 ]; then
    log "WARNING: Docker/WSL2 has only ${cpus} CPU(s). Consider 4+ CPUs for this workload."
  fi
}

ensure_lab_network() {
  if ! docker network inspect "$LAB_NETWORK" >/dev/null 2>&1; then
    log "Creating dedicated Docker network '${LAB_NETWORK}' with MTU 1400..."
    docker network create \
      --driver bridge \
      --opt com.docker.network.driver.mtu=1400 \
      "$LAB_NETWORK"
  else
    log "Docker network '${LAB_NETWORK}' already exists."
  fi
}

ensure_namespaces() {
  log "Ensuring namespaces exist..."

  kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace apps --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace "$MONITORING_NS" --dry-run=client -o yaml | kubectl apply -f -
}

ensure_postgres_password() {
  if [ "$PASSWORD_WAS_EXPLICIT" = false ] &&
     kubectl get deployment enterprise-postgres -n database >/dev/null 2>&1; then

    log "Postgres already exists and no POSTGRES_PASSWORD was exported."
    log "Reusing the existing Secret password to avoid breaking Odoo DB authentication."

    local existing_password
    existing_password="$(
      kubectl get secret postgres-credentials -n database \
        -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null \
        | base64 -d || true
    )"

    [ -n "$existing_password" ] || \
      fail "Postgres exists but its Secret password could not be read. Export POSTGRES_PASSWORD and rerun."

    POSTGRES_PASSWORD="$existing_password"
  fi
}

create_postgres_secrets() {
  log "Creating/updating Postgres credentials Secrets..."

  for ns in database apps; do
    kubectl create secret generic postgres-credentials \
      --namespace "$ns" \
      --from-literal=POSTGRES_DB=postgres \
      --from-literal=POSTGRES_USER=odoo_user \
      --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
      --dry-run=client -o yaml | kubectl apply -f -
  done
}

write_application_manifest() {
  log "Writing Kubernetes application manifest to ${APP_MANIFEST}..."

  cat <<'EOF' > "$APP_MANIFEST"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-db-pvc
  namespace: database
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 2Gi

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: enterprise-postgres
  namespace: database
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:15-alpine
          envFrom:
            - secretRef:
                name: postgres-credentials
          ports:
            - containerPort: 5432
          volumeMounts:
            - name: pgdata
              mountPath: /var/lib/postgresql/data
              subPath: pgdata
          readinessProbe:
            exec:
              command:
                - pg_isready
                - -U
                - odoo_user
                - -d
                - postgres
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          livenessProbe:
            exec:
              command:
                - pg_isready
                - -U
                - odoo_user
                - -d
                - postgres
            initialDelaySeconds: 60
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 5
          resources:
            requests:
              cpu: "100m"
              memory: "1Gi"
            limits:
              cpu: "2"
              memory: "4Gi"
      volumes:
        - name: pgdata
          persistentVolumeClaim:
            claimName: postgres-db-pvc

---
apiVersion: v1
kind: Service
metadata:
  name: enterprise-postgres
  namespace: database
spec:
  ports:
    - port: 5432
      targetPort: 5432
  selector:
    app: postgres

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: odoo-app
  namespace: apps
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
          image: odoo:17.0
          ports:
            - containerPort: 8069
          env:
            - name: HOST
              value: enterprise-postgres.database.svc.cluster.local
            - name: USER
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_USER
            - name: PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_PASSWORD
          args:
            - "--database=odoo"
          readinessProbe:
            httpGet:
              path: /web/login
              port: 8069
            initialDelaySeconds: 120
            periodSeconds: 30
            timeoutSeconds: 15
            failureThreshold: 10
          livenessProbe:
            httpGet:
              path: /web/login
              port: 8069
            initialDelaySeconds: 180
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 5
          resources:
            requests:
              cpu: "300m"
              memory: "512Mi"
            limits:
              cpu: "1"
              memory: "1536Mi"

---
apiVersion: v1
kind: Service
metadata:
  name: odoo-service
  namespace: apps
spec:
  ports:
    - port: 8069
      targetPort: 8069
  selector:
    app: odoo

---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: apps-quota
  namespace: apps
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 2Gi
    limits.cpu: "2"
    limits.memory: 4Gi
EOF
}

apply_postgres() {
  log "Applying PostgreSQL tier..."

  kubectl apply -f "$APP_MANIFEST" \
    --namespace database \
    --selector='app=postgres'
}

wait_for_postgres() {
  log "Waiting for PostgreSQL to become Ready..."

  run_with_heartbeat "Postgres rollout" "database" \
    kubectl -n database rollout status \
      deployment/enterprise-postgres \
      --timeout=180s
}

ensure_odoo_database() {
  log "Ensuring Odoo database exists in PostgreSQL..."

  local database_exists
  database_exists="$(
    kubectl exec -n database deployment/enterprise-postgres -- \
      psql -U odoo_user -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname='odoo';"
  )"

  if [ "$database_exists" = "1" ]; then
    log "Odoo database already exists."
  else
    log "Creating Odoo database..."

    kubectl exec -n database deployment/enterprise-postgres -- \
      psql -U odoo_user -d postgres \
      -c "CREATE DATABASE odoo OWNER odoo_user;"
  fi
}

apply_odoo() {
  log "Applying Odoo and application resources..."

  kubectl apply -f "$APP_MANIFEST"
}

wait_for_odoo() {
  log "Waiting for Odoo to become Ready..."

  run_with_heartbeat "Odoo rollout" "apps" \
    kubectl -n apps rollout status \
      deployment/odoo-app \
      --timeout=600s
}

initialize_odoo() {
  log "Checking Odoo database initialization..."

  local pod
  pod="$(kubectl get pod -n apps -l app=odoo \
    -o jsonpath='{.items[0].metadata.name}')"

  [ -n "$pod" ] || fail "Could not find an Odoo pod."

  log "Running Odoo base module initialization..."

  kubectl exec -n apps "$pod" -c odoo -- \
    bash -c 'odoo -d odoo -i base --stop-after-init \
      --db_host="$HOST" \
      --db_user="$USER" \
      --db_password="$PASSWORD"
  ' || {
    log "WARNING: Explicit Odoo schema initialization returned a non-zero exit code."
    log "Odoo may already be initialized; continuing with the running application."
  }
}

ensure_monitoring_helm_repo() {
  if ! helm repo list 2>/dev/null | grep -q "prometheus-community"; then
    log "Adding prometheus-community Helm repository..."
    helm repo add prometheus-community \
      https://prometheus-community.github.io/helm-charts
  fi

  helm repo update
}

install_monitoring() {
  log "Installing/upgrading kube-prometheus-stack..."

  run_with_heartbeat "Prometheus/Grafana Helm install" "$MONITORING_NS" \
    retry_cmd 3 20 \
      timeout --signal=TERM --kill-after=30 720 \
      helm upgrade --install monitoring \
        prometheus-community/kube-prometheus-stack \
        --create-namespace \
        --namespace "$MONITORING_NS" \
        --set grafana.adminPassword=admin \
        --wait \
        --timeout 10m
}

write_ingress_manifest() {
  log "Writing Ingress manifest to ${INGRESS_MANIFEST}..."

  cat <<'EOF' > "$INGRESS_MANIFEST"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: odoo-ingress
  namespace: apps
spec:
  ingressClassName: traefik
  rules:
    - host: odoo.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: odoo-service
                port:
                  number: 8069

---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitoring-ingress
  namespace: monitoring
spec:
  ingressClassName: traefik
  rules:
    - host: grafana.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: monitoring-grafana
                port:
                  number: 80

    - host: prometheus.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: monitoring-kube-prometheus-prometheus
                port:
                  number: 9090

    - host: alertmanager.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: monitoring-kube-prometheus-alertmanager
                port:
                  number: 9093
EOF
}

apply_ingress() {
  log "Applying Ingress routes..."

  kubectl apply -f "$INGRESS_MANIFEST"
}

# ---------- Main ----------
log "=================================================="
log "STARTING KUBERNETES SANDBOX LAB (k3d)"
log "=================================================="

check_deps
check_resources
ensure_lab_network

if k3d cluster list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx "$CLUSTER_NAME"; then
  log "Cluster '$CLUSTER_NAME' already exists — skipping creation."
else
  log "Creating k3d cluster '$CLUSTER_NAME' (1 server + 2 agents)..."

  run_with_heartbeat "Creating k3d cluster" "" \
    k3d cluster create "$CLUSTER_NAME" \
      --servers 1 \
      --agents 2 \
      -p "80:80@loadbalancer" \
      -p "443:443@loadbalancer" \
      --network "$LAB_NETWORK" \
      --wait \
      --timeout 90s
fi

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null

log "Waiting for all nodes to report Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

log "Checking core cluster components..."
kubectl get nodes
kubectl get pods -n kube-system

ensure_namespaces
ensure_postgres_password
create_postgres_secrets
write_application_manifest

apply_postgres
wait_for_postgres
ensure_odoo_database

apply_odoo
wait_for_odoo
initialize_odoo

ensure_monitoring_helm_repo
install_monitoring

write_ingress_manifest
apply_ingress

log "=================================================="
log "SUCCESS: LAB ARCHITECTURE INITIALIZED (k3d)"
log "=================================================="
log "Postgres password: ${POSTGRES_PASSWORD}"
log ""
log "ONE-TIME SETUP: Add these lines to your Windows hosts file"
log "(C:\\Windows\\System32\\drivers\\etc\\hosts, edited as Administrator):"
log "  127.0.0.1 odoo.lab.local"
log "  127.0.0.1 grafana.lab.local"
log "  127.0.0.1 prometheus.lab.local"
log "  127.0.0.1 alertmanager.lab.local"
log ""
log "Odoo         : http://odoo.lab.local"
log "Grafana      : http://grafana.lab.local  (login: admin / admin)"
log "Prometheus   : http://prometheus.lab.local"
log "Alertmanager : http://alertmanager.lab.local"
log ""
log "Postgres (raw TCP):"
log "  kubectl port-forward svc/enterprise-postgres -n database 5432:5432"
log "=================================================="
