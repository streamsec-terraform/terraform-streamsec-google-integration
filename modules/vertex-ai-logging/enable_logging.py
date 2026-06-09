import vertexai
from vertexai.preview.generative_models import GenerativeModel

PROJECT_ID = "staging-gcp-420609"
LOCATION = "us-central1"

vertexai.init(project=PROJECT_ID, location=LOCATION)

publisher_model = GenerativeModel("gemini-2.5-flash")

publisher_model.set_request_response_logging_config(
    enabled=True,
    sampling_rate=1.0,
    bigquery_destination=f"bq://{PROJECT_ID}.vertex_ai_logs.predictions_",
    enable_otel_logging=True,
)

print("Logging config set. Sending test request...")

response = publisher_model.generate_content("Say hello in exactly 5 words")
print(f"Response: {response.text}")
print("Done. Check BigQuery in ~2-3 minutes.")
