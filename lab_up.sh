#!/bin/bash
#
# lab-up.sh — Spin up a production-shaped Kubernetes sandbox for demos/recording.
# Uses k3d (Docker-based k3s clusters). Idempotent: safe to re-run.

set -euo pipefail

# ---------- Config ----------
CLUSTER_NAME="enterprise-lab"
APP_MANIFEST="odoo-multi-ns.yaml"
MONITORING_NS="monitoring"
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
  log "❌ ERROR: $*"
  exit 1
}

retry_cmd() {
  local attempts="$1" delay="$2"
  shift 2
  local n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      fail "Command failed after $attempts attempts: $*"
    fi
    log "⚠️  Attempt $n/$attempts failed. Retrying in ${delay}s..."
    n=$((n + 1))
    sleep "$delay"
  done
}

run_with_heartbeat() {
  local desc="$1" watch_ns="$2"
  shift 2
  log "▶️  ${desc}..."
  ("$@") &
  local cmd_pid=$!
  local elapsed=0
  local interval=15
  while kill -0 "$cmd_pid" 2>/dev/null; do
    sleep "$interval"
    elapsed=$((elapsed + interval))
    kill -0 "$cmd_pid" 2>/dev/null || break
    if [ -n "$watch_ns" ]; then
      local snapshot
      snapshot=$(kubectl get pods -n "$watch_ns" --no-headers 2>/dev/null | awk '{printf "%s:%s  ", $1, $2}')
      log "⏳ (${elapsed}s elapsed) ${desc} — pods: ${snapshot:-not created yet}"
    else
      log "⏳ (${elapsed}s elapsed) ${desc}..."
    fi
  done
  wait "$cmd_pid"
  local status=$?
  if [ "$status" -ne 0 ]; then
    fail "${desc} failed after ${elapsed}s (exit code ${status})"
  fi
  log "✅ ${desc} completed in ${elapsed}s"
}

trap 'log "❌ Script failed at line $LINENO. See $LOG_FILE for details."' ERR

check_deps() {
  log "🔍 Checking required tools..."
  local missing=()
  for bin in k3d kubectl helm docker openssl; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    fail "Missing required tools: ${missing[*]}. Install them before running this script."
  fi
  docker info >/dev/null 2>&1 || fail "Docker daemon isn't reachable. Is Docker/WSL2 integration running?"
}

check_resources() {
  log "🔍 Checking Docker/WSL2 resource allocation..."
  local mem_bytes cpus
  mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
  local mem_gb=$((mem_bytes / 1024 / 1024 / 1024))

  if [ "$mem_gb" -gt 0 ] && [ "$mem_gb" -lt 6 ]; then
    log "⚠️  Docker/WSL2 has only ~${mem_gb}GB memory allocated. Running Postgres + Odoo + the full"
    log "⚠️  monitoring stack concurrently can push k3s's embedded SQLite datastore into failure under"
    log "⚠️  this level of I/O pressure (symptom: 'Transaction commit failed', server restarts)."
    log "⚠️  Consider raising the WSL2 memory limit in .wslconfig to 6-8GB+ if this recurs."
  fi
  if [ "$cpus" -gt 0 ] && [ "$cpus" -lt 4 ]; then
    log "⚠️  Docker/WSL2 has only ${cpus} CPU(s) allocated. Consider raising to 4+ for this workload."
  fi
}

LAB_NETWORK="k3d-lab-net"
ensure_lab_network() {
  if ! docker network inspect "$LAB_NETWORK" >/dev/null 2>&1; then
    log "🌐 Creating dedicated Docker network '${LAB_NETWORK}' with MTU 1400 (avoids in-cluster image-pull"
    log "🌐 TCP resets over WSL2's extra bridge hop)..."
    docker network create --driver bridge --opt com.docker.network.driver.mtu=1400 "$LAB_NETWORK"
  fi
}

log "=================================================="
log "🚀 STARTING KUBERNETES SANDBOX LAB (k3d)"
log "=================================================="
check_deps
check_resources
ensure_lab_network

if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER_NAME"; then
  log "✅ Cluster '$CLUSTER_NAME' already exists — skipping creation."
else
  log "🏗️  Spinning up k3d cluster '$CLUSTER_NAME' (1 server + 2 agents)..."
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

log "⏳ Waiting for all nodes to report Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

log "⏳ Waiting for core cluster components (CoreDNS, local-path-provisioner) to be ready..."
kubectl wait --for=condition=Ready pods -n kube-system --all --timeout=120s || true

log "📂 Ensuring namespaces exist..."
kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace apps     --dry-run=client -o yaml | kubectl apply -f -

if [ "$PASSWORD_WAS_EXPLICIT" = false ] && kubectl get deployment enterprise-postgres -n database >/dev/null 2>&1; then
  log "⚠️  Postgres already exists and no POSTGRES_PASSWORD was exported — reusing the existing Secret's password to avoid breaking Odoo's DB auth."
  EXISTING_PASSWORD="$(kubectl get secret postgres-credentials -n database -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d || true)"
  [ -n "$EXISTING_PASSWORD" ] || fail "Postgres deployment exists but its Secret's password couldn't be read. Export POSTGRES_PASSWORD manually and rerun."
  POSTGRES_PASSWORD="$EXISTING_PASSWORD"
fi

log "🔐 Creating/updating Postgres credentials Secret (database + apps namespaces)..."
for ns in database apps; do
  kubectl create secret generic postgres-credentials \
    --namespace "$ns" \
    --from-literal=POSTGRES_DB=postgres \
    --from-literal=POSTGRES_USER=odoo_user \
    --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -
done

cat <<'EOF' > "$APP_MANIFEST"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-db-pvc
  namespace: database
spec:
  accessModes: ["ReadWriteOnce"]
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
      initContainers:
      - name: init-odoo-user
        image: postgres:15-alpine
        envFrom:
        - secretRef:
            name: postgres-credentials
        command: ["sh", "-c"]
        args:
          - |
            until pg_isready -h localhost -U postgres; do sleep 2; done
            psql -U postgres -d postgres -c "CREATE ROLE odoo_user LOGIN PASSWORD '${POSTGRES_PASSWORD}'" || true
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
            command: ["pg_isready", "-U", "postgres", "-d", "postgres"]
          initialDelaySeconds: 30
          periodSeconds: 10
        livenessProbe:
          exec:
            command: ["pg_isready", "-U", "postgres", "-d", "postgres"]
          initialDelaySeconds: 60
          periodSeconds: 20
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
        # NOTE: the official odoo image's entrypoint only reads HOST, USER,
        # PASSWORD, PORT from the environment — it does NOT read a "DB_NAME"
        # variable, so setting one has no effect. To actually pre-select a
        # database and skip the Database Manager screen, pass it as a CLI
        # arg via `--database` (Odoo's real supported mechanism for this).
        args: ["--database=odoo"]
        readinessProbe:
          httpGet:
            path: /web/login
            port: 8069
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 50
          failureThreshold: 10
        livenessProbe:
          httpGet:
            path: /web/login
            port: 8069
          initialDelaySeconds: 60
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

log "📦 Applying Postgres tier first..."
kubectl apply -f "$APP_MANIFEST" --selector=app=postgres 2>/dev/null || \
  kubectl apply -f <(awk '/^---$/{c++} c<=2' "$APP_MANIFEST")

log "⏳ Waiting for Postgres to be ready before starting Odoo (dependency ordering)..."
run_with_heartbeat "Postgres rollout" "database" \
  kubectl -n database rollout status deployment/enterprise-postgres --timeout=180s

log "🔧 Ensuring Odoo user and database exist in Postgres..."
kubectl exec -n database deployment/enterprise-postgres -- \
  psql -U postgres -d postgres -c "DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'odoo_user') THEN
      CREATE ROLE odoo_user LOGIN PASSWORD '${POSTGRES_PASSWORD}';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'odoo') THEN
      CREATE DATABASE odoo OWNER odoo_user;
    END IF;
  END \$\$;" || true


log "🔧 Ensuring Odoo database exists in Postgres..."
kubectl exec -n database deployment/enterprise-postgres -- \
  psql -U odoo_user -d postgres -c "CREATE DATABASE odoo;" || true

log "📦 Applying remaining application manifests (Odoo, quotas)..."
kubectl apply -f "$APP_MANIFEST"

log "⏳ Waiting for Odoo to become ready (the image is ~600MB, first pull can take several minutes on a normal connection)..."
run_with_heartbeat "Odoo rollout" "apps" \
  kubectl -n apps rollout status deployment/odoo-app --timeout=600s

log "🔧 Initializing Odoo database schema..."
POD=$(kubectl get pod -n apps -l app=odoo -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n apps $POD -c odoo -- \
  bash -c 'odoo -d odoo -i base --stop-after-init \
    --db_host=$HOST --db_user=$USER --db_password=$PASSWORD' || true

ensure_clean_helm_release() {
  local rel="$1" ns="$2"
  local status
  status="$(helm status "$rel" -n "$ns" -o json 2>/dev/null | grep -o '"status":"[a-zA-Z-]*"' | head -1 | cut -d'"' -f4 || true)"

  if [ -z "$status" ]; then
    return 0
  fi

  if [ "$status" != "deployed" ]; then
    log "⚠️  Existing Helm release '${rel}' in namespace '${ns}' has status '${status}', not 'deployed'."
    log "⚠️  Clearing its release history so this run starts fresh (no effect on already-running pods)."
    kubectl get secrets -n "$ns" -l "owner=helm,name=${rel}" -o name 2>/dev/null | xargs -r kubectl delete -n "$ns" || true
  fi
}

log "📊 Setting up Prometheus & Grafana via Helm..."
ensure_clean_helm_release "monitoring" "$MONITORING_NS"
if ! helm repo list 2>/dev/null | grep -q "prometheus-community"; then
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
fi
helm repo update

log "📥 Downloading and installing kube-prometheus-stack (large chart + several container images — this is the slowest step, can take 5-15+ min on a modest connection)..."
run_with_heartbeat "Prometheus/Grafana Helm install" "$MONITORING_NS" \
  retry_cmd 3 20 timeout --signal=TERM --kill-after=15 600 \
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --create-namespace \
  --namespace "$MONITORING_NS" \
  --set grafana.adminPassword="admin" \
  --wait --timeout 9m

helm_status="$(helm status monitoring -n "$MONITORING_NS" -o json 2>/dev/null | grep -o '"status":"[a-zA-Z-]*"' | head -1 || true)"
if [ -n "$helm_status" ] && ! echo "$helm_status" | grep -q "deployed"; then
  log "⚠️  Helm release status is '${helm_status}', not 'deployed'. Check manually with: helm status monitoring -n ${MONITORING_NS}"
fi

log "🌐 Setting up permanent Ingress routes (Odoo, Grafana, Prometheus, Alertmanager)..."
cat <<'EOF' > ingress.yaml
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

kubectl apply -f ingress.yaml

log "=================================================="
log "🎯 SUCCESS: LAB ARCHITECTURE INITIALIZED (k3d)"
log "=================================================="
log "Postgres password (auto-generated, stored only in the Secret): ${POSTGRES_PASSWORD}"
log ""
log "⚠️  ONE-TIME SETUP REQUIRED: add these lines to your Windows hosts file"
log "    (C:\\Windows\\System32\\drivers\\etc\\hosts, edited as Administrator):"
log "      127.0.0.1 odoo.lab.local"
log "      127.0.0.1 grafana.lab.local"
log "      127.0.0.1 prometheus.lab.local"
log "      127.0.0.1 alertmanager.lab.local"
log ""
log "👉 Odoo         : http://odoo.lab.local"
log "👉 Grafana      : http://grafana.lab.local  (login: admin / admin)"
log "👉 Prometheus   : http://prometheus.lab.local"
log "👉 Alertmanager : http://alertmanager.lab.local"
log ""
log "👉 Postgres (still needs port-forward — raw TCP, not HTTP):"
log "   kubectl port-forward svc/enterprise-postgres -n database 5432:5432"
log "=================================================="
