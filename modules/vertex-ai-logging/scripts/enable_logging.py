"""Enable request-response logging on a Vertex AI publisher model."""

import argparse
import sys

import vertexai
from vertexai.preview.generative_models import GenerativeModel


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True)
    parser.add_argument("--location", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--sampling-rate", type=float, default=1.0)
    parser.add_argument("--bq-destination", required=True)
    args = parser.parse_args()

    vertexai.init(project=args.project, location=args.location)

    model = GenerativeModel(args.model)
    model.set_request_response_logging_config(
        enabled=True,
        sampling_rate=args.sampling_rate,
        bigquery_destination=args.bq_destination,
        enable_otel_logging=True,
    )

    print(f"Enabled request-response logging for {args.model} -> {args.bq_destination}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
