#!/bin/bash
set -e

echo "=== Sending Gemini prompt ==="
python3 -W ignore -c "
import vertexai
from vertexai.preview.generative_models import GenerativeModel
vertexai.init(project='staging-gcp-420609', location='us-central1')
model = GenerativeModel('gemini-2.5-flash')
response = model.generate_content('What is 2+2? Reply in one word.')
print('Response:', response.text)
"

echo ""
echo "=== Waiting 60s for BQ ingestion ==="
sleep 60

echo "=== Checking BigQuery ==="
bq query --project_id=staging-gcp-420609 --use_legacy_sql=false --format=pretty \
  'SELECT logging_time, model, api_method FROM `staging-gcp-420609.vertex_ai_logs.predictions_*` ORDER BY logging_time DESC LIMIT 10'
