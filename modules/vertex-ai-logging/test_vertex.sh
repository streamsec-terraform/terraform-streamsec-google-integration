#!/bin/bash
set -e

echo "=== Getting access token from instance metadata ==="
TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

echo "=== Calling Gemini 2.5 Flash via Vertex AI ==="
RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://us-central1-aiplatform.googleapis.com/v1/projects/staging-gcp-420609/locations/us-central1/publishers/google/models/gemini-2.5-flash:generateContent" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Say hello in exactly 5 words"}]}]}')

echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
echo ""
echo "=== Done. Check BigQuery in ~2-3 minutes ==="
