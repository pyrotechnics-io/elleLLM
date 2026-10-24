#!/bin/sh
# Lambda handler (via the Lambda Web Adapter's exec wrapper) and local entry
# point: fetch the model if needed, then start llama-cpp-python's
# OpenAI-compatible server. All server settings come from environment
# variables (MODEL, MODEL_ALIAS, N_CTX, API_KEY, PORT, ...);
# see https://llama-cpp-python.readthedocs.io/en/latest/server/
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
export PYTHONPATH="${HERE}${PYTHONPATH:+:$PYTHONPATH}"

if [ -n "$MODEL_S3_BUCKET" ]; then
    export MODEL="${MODEL:-/tmp/model.gguf}"
    python3 "$HERE/fetch_model.py" "$MODEL_S3_BUCKET" "$MODEL_S3_KEY" "$MODEL"
fi

# Lambda's vCPU count scales with memory; use all of them for inference.
export N_THREADS="${N_THREADS:-$(nproc)}"
export N_THREADS_BATCH="${N_THREADS_BATCH:-$N_THREADS}"
export MODEL_ALIAS="${MODEL_ALIAS:-qwen2.5-0.5b-instruct}"
export PORT="${PORT:-8080}"

exec python3 -m llama_cpp.server
