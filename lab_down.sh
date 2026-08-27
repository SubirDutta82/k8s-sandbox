#!/bin/bash
#
# lab-down.sh — Tear down the k3d sandbox and reclaim host RAM.
# Runs best-effort: one failed cleanup step won't abort the rest.

set -uo pipefail

CLUSTER_NAME="enterprise-lab"
LOG_FILE="lab-down.log"
AUTO_YES=false

for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_YES=true ;;
  esac
done

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

log "=================================================="
log "🛑 TEARING DOWN LAB AND RECLAIMING HOST RESOURCES"
log "=================================================="

if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER_NAME"; then
  if [ "$AUTO_YES" = false ]; then
    read -r -p "Delete cluster '${CLUSTER_NAME}' and all its workloads? [y/N] " confirm
    case "$confirm" in
      [yY][eE][sS]|[yY]) ;;
      *) log "Aborted by user."; exit 0 ;;
    esac
  fi
  log "🗑️  Deleting k3d cluster '${CLUSTER_NAME}'..."
  k3d cluster delete "$CLUSTER_NAME" || log "⚠️  Cluster deletion reported an error (continuing)."
else
  log "ℹ️  No cluster named '${CLUSTER_NAME}' found — nothing to delete."
fi

log "🧹 Cleaning up generated config files..."
rm -f odoo-multi-ns.yaml

log "=================================================="
log "✨ SYSTEM CLEARED: all lab resources pruned."
log "=================================================="
