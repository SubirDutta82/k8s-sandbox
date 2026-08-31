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

# Retry a command a few times with a delay between attempts — useful for
# steps that hit transient network blips (e.g. downloading Helm chart
# tarballs from a CDN on a slow connection).
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

# Run a long-running command in the background while printing periodic
# "still working" status lines to the log — gives visibility into slow
# steps (image pulls, chart downloads) without needing a second terminal.
# Usage: run_with_heartbeat "description" "namespace-to-snapshot-or-empty" cmd args...
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

# k3s's default single-node datastore (embedded SQLite via "kine") is known
# to fall over under sustained concurrent write load — this stack (Postgres +
# Odoo + the full kube-prometheus-stack) generates exactly that kind of load.
# Under-resourced Docker/WSL2 allocations have caused the k3s server process
# to hit "Transaction commit failed" and crash outright. This is a soft
# warning only — it won't block the run, since the cluster usually recovers
# on its own, but it explains the failure mode if you hit it.
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

# ---------- 0. Preflight ----------
log "=================================================="
log "🚀 STARTING KUBERNETES SANDBOX LAB (k3d)"
log "=================================================="
check_deps
check_resources

# ---------- 1. Cluster (idempotent) ----------
if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER_NAME"; then
  log "✅ Cluster '$CLUSTER_NAME' already exists — skipping creation."
  log "ℹ️  NOTE: port mappings (80/443 for Ingress) are only set at cluster CREATION time."
  log "ℹ️  If this cluster was created before Ingress support was added to this script,"
  log "ℹ️  run ./lab-down.sh then rerun this script to pick up the new port mappings."
else
  log "🏗️  Spinning up k3d cluster '$CLUSTER_NAME' (1 server + 2 agents)..."
  run_with_heartbeat "Creating k3d cluster" "" \
    k3d cluster create "$CLUSTER_NAME" \
    --servers 1 \
    --agents 2 \
    -p "80:80@loadbalancer" \
    -p "443:443@loadbalancer" \
    --wait \
    --timeout 90s
fi

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null

# ---------- 1b. Wait for the cluster to be truly ready, not just "created" ----------
# k3d reporting "created successfully" only means the control plane answered —
# it does NOT guarantee node readiness or that in-cluster controllers like the
# local-path-provisioner (needed to bind our PVC) have finished starting.
# Racing ahead of this causes PVCs to sit unbound and deployments to time out.
log "⏳ Waiting for all nodes to report Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

log "⏳ Waiting for core cluster components (CoreDNS, local-path-provisioner) to be ready..."
kubectl -n kube-system rollout status deployment/coredns --timeout=90s || true
kubectl -n kube-system rollout status deployment/local-path-provisioner --timeout=90s || true

# ---------- 2. Namespaces ----------
log "📂 Ensuring namespaces exist..."
kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace apps     --dry-run=client -o yaml | kubectl apply -f -

# ---------- 3. Secret (never store plaintext creds in a committed manifest) ----------
# NOTE: Secrets are namespace-scoped. Postgres reads it via envFrom in the
# 'database' namespace; Odoo reads it via secretKeyRef in the 'apps' namespace.
# It must exist in BOTH namespaces or Odoo's pod will fail with
# "secret postgres-credentials not found".
#
# SAFETY CHECK: Postgres only applies POSTGRES_PASSWORD on its first-ever
# initdb. If Postgres is already running (data already initialized) and this
# script generates a NEW random password, the Secret and the running database
# fall out of sync and Odoo starts failing to authenticate. So: if Postgres
# already exists and the caller did NOT explicitly export a password, reuse
# whatever password is already sitting in the existing Secret instead of
# the freshly-generated random one.
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

# ---------- 4. App manifest (references the Secret, adds probes/limits) ----------
log "📝 Generating application manifest..."
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
            command: ["pg_isready", "-U", "odoo_user"]
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
        livenessProbe:
          exec:
            command: ["pg_isready", "-U", "odoo_user"]
          initialDelaySeconds: 15
          periodSeconds: 10
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "300m"
            memory: "512Mi"
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
        readinessProbe:
          httpGet:
            path: /web/login
            port: 8069
          initialDelaySeconds: 40
          periodSeconds: 15
          timeoutSeconds: 10
          failureThreshold: 5
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

log "📦 Applying remaining application manifests (Odoo, quotas)..."
kubectl apply -f "$APP_MANIFEST"

log "⏳ Waiting for Odoo to become ready (the image is ~600MB, first pull can take several minutes on a normal connection)..."
run_with_heartbeat "Odoo rollout" "apps" \
  kubectl -n apps rollout status deployment/odoo-app --timeout=420s

# ---------- 5. Observability ----------
log "📊 Setting up Prometheus & Grafana via Helm..."
if ! helm repo list 2>/dev/null | grep -q "prometheus-community"; then
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
fi
helm repo update

log "📥 Downloading and installing kube-prometheus-stack (large chart + several container images — this is the slowest step, can take 5-15+ min on a modest connection)..."
# NOTE: helm's own --timeout is NOT a hard guarantee. Its --wait mechanism uses
# a Kubernetes watch connection that can silently stall on flaky/NAT'd networks
# (common under WSL2), causing helm to hang well past its stated --timeout
# without ever returning or erroring. We wrap it in the coreutils `timeout`
# command for a real, unconditional wall-clock kill, so retry_cmd can actually
# retry instead of blocking forever on one stuck attempt.
run_with_heartbeat "Prometheus/Grafana Helm install" "$MONITORING_NS" \
  retry_cmd 3 20 timeout --signal=TERM --kill-after=15 600 \
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --create-namespace \
  --namespace "$MONITORING_NS" \
  --set grafana.adminPassword="admin" \
  --wait --timeout 9m

# Belt-and-braces: even if the helm wait itself was flaky, verify the release
# actually landed in a healthy state before declaring success.
helm_status="$(helm status monitoring -n "$MONITORING_NS" -o json 2>/dev/null | grep -o '"status":"[a-zA-Z-]*"' | head -1 || true)"
if [ -n "$helm_status" ] && ! echo "$helm_status" | grep -q "deployed"; then
  log "⚠️  Helm release status is '${helm_status}', not 'deployed'. Check manually with: helm status monitoring -n ${MONITORING_NS}"
fi

# ---------- 6. Ingress (permanent, zero-terminal access via Traefik) ----------
# k3s ships with Traefik as its default ingress controller. Combined with the
# 80/443 port mappings on the k3d cluster, these Ingress resources give you
# stable URLs that work with no `kubectl port-forward` running at all.
# NOTE: this only covers HTTP(S) traffic. Postgres is a raw TCP protocol, not
# HTTP, so it isn't (and can't be) covered by a standard Ingress — keep using
# `kubectl port-forward` for direct Postgres access.
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

# ---------- 7. Summary ----------
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
