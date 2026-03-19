#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
OVERLAY="${1:-route}"

if [[ ! -d "$REPO_ROOT/manifests/overlays/$OVERLAY" ]]; then
  echo "Unknown overlay: $OVERLAY"
  echo "Usage: ./scripts/deploy.sh [route|gateway|ambient]"
  exit 1
fi

echo "=== RHOAI Super Slim Demo ==="
echo "Overlay: $OVERLAY"
echo ""

echo "--- Applying manifests ---"
oc apply -k "$REPO_ROOT/manifests/overlays/$OVERLAY"

echo ""
echo "--- Waiting for KServe controller ---"
oc rollout status deployment/kserve-controller-manager \
  -n redhat-ods-applications --timeout=120s 2>/dev/null || true

echo "Verifying InferenceService CRD exists..."
until oc api-resources 2>/dev/null | grep -q inferenceservices; do
  sleep 5
done
echo "KServe CRDs registered."

echo ""
echo "--- Waiting for model pod ---"
sleep 10
POD=$(oc get pods -n super-slim-demo -l serving.kserve.io/inferenceservice=phi-4-mini \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$POD" ]; then
  echo "Pod: $POD"
  echo "Model is downloading from HuggingFace (~7.5GB, takes several minutes)..."
  echo "Monitor with: oc logs -n super-slim-demo $POD -c storage-initializer -f"
fi

echo ""
echo "=== Deployment initiated ==="
echo ""
echo "Next steps:"
echo "  1. Wait for model to finish loading:"
echo "     oc get pods -n super-slim-demo -w"
echo ""
echo "  2. Once pod shows 1/1 Running, test the model:"
echo "     ./scripts/test-chat.sh"
