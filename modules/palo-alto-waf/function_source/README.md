# function_source (generated, do not edit here)

The Palo Alto WAF/NGFW connector for Cloud Functions, as built by lightlytics:

```sh
python lambda_functions/waf/build.py --cloud gcp --vendor palo-alto --out <dir>
```

Its code lives in `lightlytics/lambda_functions/waf` (shared library `stream_connector/`, vendor
adapter `adapters/palo_alto.py`, GCP entry point `main.py`). Change it there and copy the build
here; see "Function-source synchronization" in the module README.
