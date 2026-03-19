#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-super-slim-demo}"
ISVC_NAME="${ISVC_NAME:-phi-4-mini}"

# Determine endpoint: prefer Route, fall back to port-forward
ROUTE_HOST=$(oc get route "$ISVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

if [ -n "$ROUTE_HOST" ]; then
  BASE_URL="https://$ROUTE_HOST"
  CURL_OPTS="-k"
else
  echo "No route found. Using port-forward to service on localhost:8080..."
  oc port-forward -n "$NAMESPACE" svc/"${ISVC_NAME}-predictor" 8080:80 &
  PF_PID=$!
  trap "kill $PF_PID 2>/dev/null" EXIT
  sleep 3
  BASE_URL="http://localhost:8080"
  CURL_OPTS=""
fi

echo "=== RHOAI Super Slim - Model Test ==="
echo "Endpoint: $BASE_URL"
echo ""

# 1. Health check
echo "--- Health Check ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" $CURL_OPTS "$BASE_URL/v1/models" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
  echo "Model server is healthy (HTTP $HTTP_CODE)"
  curl -s $CURL_OPTS "$BASE_URL/v1/models" | python3 -m json.tool 2>/dev/null || true
else
  echo "Model server returned HTTP $HTTP_CODE (may still be loading)"
  echo "Check pod status: oc get pods -n $NAMESPACE"
  exit 1
fi

echo ""

# 2. Chat completion
echo "--- Chat Completion ---"
echo "Prompt: 'What is OpenShift AI in one sentence?'"
echo ""

RESPONSE=$(curl -s $CURL_OPTS "$BASE_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "phi-4-mini",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant. Be concise."},
      {"role": "user", "content": "What is OpenShift AI in one sentence?"}
    ],
    "max_tokens": 128,
    "temperature": 0.7
  }')

echo "$RESPONSE" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    msg = r['choices'][0]['message']['content']
    usage = r.get('usage', {})
    print(f'Response: {msg}')
    print()
    print(f'Tokens - prompt: {usage.get(\"prompt_tokens\", \"?\")}, '
          f'completion: {usage.get(\"completion_tokens\", \"?\")}, '
          f'total: {usage.get(\"total_tokens\", \"?\")}')
except Exception as e:
    print(f'Raw response: {sys.stdin.read() if hasattr(sys.stdin, \"read\") else r}')
    print(f'Parse error: {e}')
" 2>/dev/null || echo "$RESPONSE"

echo ""
echo "=== Test Complete ==="
