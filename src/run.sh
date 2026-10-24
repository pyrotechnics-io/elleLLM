#!/bin/sh
# Lambda handler (via the Lambda Web Adapter's exec wrapper) and local entry
# point: start llama-cpp-python's OpenAI-compatible server. All server
# settings come from environment variables (MODEL, MODEL_ALIAS, N_CTX,
# API_KEY, PORT, ...); see https://llama-cpp-python.readthedocs.io/en/latest/server/
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
export PYTHONPATH="${HERE}${PYTHONPATH:+:$PYTHONPATH}"

# The model ships inside the deployment package next to this script.
export MODEL="${MODEL:-$HERE/model.gguf}"
export MODEL_ALIAS="${MODEL_ALIAS:-smollm2-135m-instruct}"
export PORT="${PORT:-8080}"

# Lambda's vCPU count scales with memory; use all of them for inference.
export N_THREADS="${N_THREADS:-$(nproc)}"
export N_THREADS_BATCH="${N_THREADS_BATCH:-$N_THREADS}"

exec python3 -m llama_cpp.server
