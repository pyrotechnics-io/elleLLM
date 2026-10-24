#!/bin/sh
# Start llama-cpp-python's OpenAI-compatible server. All settings come from
# environment variables (MODEL, MODEL_ALIAS, N_CTX, API_KEY, ...), which the
# server reads directly; see https://llama-cpp-python.readthedocs.io/en/latest/server/
set -e

# Lambda's vCPU count scales with memory; use all of them for inference.
export N_THREADS="${N_THREADS:-$(nproc)}"
export N_THREADS_BATCH="${N_THREADS_BATCH:-$N_THREADS}"

exec python -m llama_cpp.server
