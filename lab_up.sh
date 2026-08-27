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

# ---------- 0. Preflight ----------
log "=================================================="
log "🚀 STARTING KUBERNETES SANDBOX LAB (k3d)"
log "=================================================="
check_deps

# ---------- 1. Cluster (idempotent) ----------
if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER_NAME"; then
  log "✅ Cluster '$CLUSTER_NAME' already exists — skipping creation."
else
  log "🏗️  Spinning up k3d cluster '$CLUSTER_NAME' (1 server + 2 agents)..."
  k3d cluster create "$CLUSTER_NAME" \
    --servers 1 \
    --agents 2 \
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
kubectl -n database rollout status deployment/enterprise-postgres --timeout=180s

log "📦 Applying remaining application manifests (Odoo, quotas)..."
kubectl apply -f "$APP_MANIFEST"

log "⏳ Waiting for Odoo to become ready (the image is ~600MB, first pull can take several minutes on a normal connection)..."
kubectl -n apps rollout status deployment/odoo-app --timeout=420s

# ---------- 5. Observability ----------
log "📊 Setting up Prometheus & Grafana via Helm..."
if ! helm repo list 2>/dev/null | grep -q "prometheus-community"; then
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
fi
helm repo update

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --create-namespace \
  --namespace "$MONITORING_NS" \
  --set grafana.adminPassword="admin" \
  --wait --timeout 5m

# ---------- 6. Summary ----------
log "=================================================="
log "🎯 SUCCESS: LAB ARCHITECTURE INITIALIZED (k3d)"
log "=================================================="
log "Postgres password (auto-generated, stored only in the Secret): ${POSTGRES_PASSWORD}"
log ""
log "👉 Odoo   (http://localhost:8069): kubectl port-forward svc/odoo-service -n apps 8069:8069"
log "👉 Grafana(http://localhost:3000): kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80"
log "   Grafana login: admin / admin"
log "=================================================="
