# Phi-4-mini (GGUF) served by llama-cpp-python's OpenAI-compatible server,
# running inside AWS Lambda via the Lambda Web Adapter.

ARG PYTHON_VERSION=3.12

# ---- build stage: compile llama-cpp-python for a generic x86_64 CPU ----------
FROM python:${PYTHON_VERSION}-slim-bookworm AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential cmake curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /tmp/requirements.txt
# GGML_NATIVE=OFF so the binary doesn't assume the build host's exact CPU
# (Lambda hosts vary); AVX2/FMA are available on all x86_64 Lambda hardware.
ENV CMAKE_ARGS="-DGGML_NATIVE=OFF -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON"
RUN pip install --no-cache-dir --prefix=/install -r /tmp/requirements.txt

# ---- model stage: fetch the GGUF weights once at build time ------------------
FROM build AS model
ARG MODEL_URL=https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/main/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf
RUN mkdir -p /models \
 && curl -fL --retry 5 -o /models/model.gguf "${MODEL_URL}"

# ---- runtime image ------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends libgomp1 \
 && rm -rf /var/lib/apt/lists/*

# Lambda Web Adapter turns Lambda invocations into plain HTTP requests on :8080.
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 /lambda-adapter /opt/extensions/lambda-adapter

COPY --from=build /install /usr/local
COPY --from=model /models/model.gguf /opt/model/model.gguf
COPY scripts/run.sh /opt/run.sh

ENV MODEL=/opt/model/model.gguf \
    MODEL_ALIAS=phi-4-mini \
    HOST=0.0.0.0 \
    PORT=8080 \
    N_CTX=4096 \
    AWS_LWA_PORT=8080 \
    AWS_LWA_READINESS_CHECK_PATH=/v1/models \
    AWS_LWA_INVOKE_MODE=response_stream \
    PYTHONUNBUFFERED=1

EXPOSE 8080
CMD ["/opt/run.sh"]
