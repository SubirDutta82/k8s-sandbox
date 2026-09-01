#!/bin/bash
#
# check_crd_sizes.sh — checks the last-applied-configuration annotation size
# on every Prometheus Operator CRD. Sizes at or near 262144 bytes (256KB)
# indicate the known kubectl annotation size-limit issue with this chart.

set -uo pipefail

echo "Checking last-applied-configuration annotation size on all monitoring.coreos.com CRDs..."
echo "=========================================================================="

for crd in $(kubectl get crds -o name | grep monitoring.coreos.com); do
  size=$(kubectl get "$crd" -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' 2>/dev/null | wc -c)
  echo "$crd : $size bytes"
done

echo "=========================================================================="
echo "Anything at or near 262144 bytes confirms the annotation size-limit issue."
echo "A 0 for a given CRD just means that annotation isn't set — not itself a problem."
