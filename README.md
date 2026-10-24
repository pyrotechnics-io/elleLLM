# elleLLM

A small conversational model running **entirely inside one AWS Lambda function**,
exposed as an **OpenAI-compatible** Chat Completions API. No GPU, no external
inference service, and no container image or ECR: it's a plain zip on the
managed `python3.12` runtime, and the model file sits in S3.

- **Model:** [Qwen2.5-0.5B-Instruct](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF),
  4-bit `Q4_K_M` GGUF (~0.4 GB), Apache-2.0.
- **Runtime:** [llama-cpp-python](https://github.com/abetlen/llama-cpp-python) and its
  built-in OpenAI-compatible server (`python -m llama_cpp.server`). There is no
  hand-written API code: request/response shapes, streaming and auth all come
  from that library.
- **Glue:** the [AWS Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter)
  layer runs that HTTP server inside Lambda and forwards Function URL requests
  to it, with response streaming enabled.
- **IaC:** AWS SAM (`template.yaml`).

## How it works

```
client (OpenAI SDK) ──HTTPS──▶ Lambda Function URL (streaming)
                                   │
                                   ▼
               Lambda Web Adapter layer ──▶ llama_cpp.server on :8080
                                                  │
              cold start only: S3 ──▶ /tmp/model.gguf (parallel download)
```

The deployment package is only the Python dependencies (~85 MB unzipped,
inside the 250 MB zip limit). A model can't go in the zip, so on each cold start
`src/fetch_model.py` pulls it from the stack's S3 bucket into `/tmp` with
parallel ranged GETs, then the server memory-maps it. Warm invocations reuse it.

## Why Qwen2.5-0.5B

It was picked to keep the function light and fast: ~0.4 GB loads in a few
seconds on a cold start, needs well under 1 GB of RAM, and generates tens of
tokens per second on a couple of Lambda vCPUs. It's one of the best instruction
models at this size and has a proper chat template.

**Want better answers?** The model is just a file in S3. For example, Phi-4-mini
(3.8B, ~2.5 GB) is much smarter but has slower cold starts and generation:

```bash
curl -L -o phi.gguf https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/main/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf
aws s3 cp phi.gguf "s3://$MODEL_BUCKET/phi.gguf"
sam deploy --parameter-overrides ModelKey=phi.gguf ModelAlias=phi-4-mini MemorySize=10240
```

(For a model that size also raise `EphemeralStorage` in `template.yaml` to 4096.)

## Endpoints

| Method | Path                    | Notes                                   |
|--------|-------------------------|-----------------------------------------|
| POST   | `/v1/chat/completions`  | `model`, `messages`, `max_tokens`, `temperature`, `top_p`, `stop`, `stream` (default `false`), etc. |
| POST   | `/v1/completions`       | Legacy text completions                 |
| GET    | `/v1/models`            | Returns `qwen2.5-0.5b-instruct`         |

## Deploy

Prerequisites: AWS CLI with credentials, [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html),
and Docker (only used by `sam build` to compile llama.cpp in the Lambda build
image so the binary matches the runtime; nothing is pushed to ECR).

```bash
# 1. Build and deploy the function (samconfig.toml has the build flags).
sam build
sam deploy --guided --parameter-overrides ApiKey=sk-choose-a-secret

# 2. Upload the model to the bucket the stack created (output "ModelBucket").
MODEL_BUCKET=$(aws cloudformation describe-stacks --stack-name <your-stack> \
  --query "Stacks[0].Outputs[?OutputKey=='ModelBucket'].OutputValue" --output text)
curl -L -o qwen.gguf https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
aws s3 cp qwen.gguf "s3://$MODEL_BUCKET/qwen2.5-0.5b-instruct-q4_k_m.gguf"
```

The deploy prints `BaseUrl`, something like
`https://abc123.lambda-url.us-east-1.on.aws/v1`.

Parameters:

| Parameter     | Default | Meaning |
|---------------|---------|---------|
| `ApiKey`      | empty   | Bearer token clients must send. Empty means the URL is open to anyone. **Set one.** |
| `ModelKey`    | `qwen2.5-0.5b-instruct-q4_k_m.gguf` | S3 key of the GGUF in the model bucket. |
| `ModelAlias`  | `qwen2.5-0.5b-instruct` | Model id reported by `/v1/models`. |
| `MemorySize`  | `4096`  | MB; also sets vCPUs (≈2.3 at 4096) and therefore speed. |
| `ContextSize` | `4096`  | Prompt + completion tokens. |
| `WebAdapterLayerArn` | public layer | Override the Lambda Web Adapter layer ARN if needed. |

## Call it with the OpenAI SDK

Just change `base_url` (and use your `ApiKey`):

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://abc123.lambda-url.us-east-1.on.aws/v1",
    api_key="sk-choose-a-secret",
)

resp = client.chat.completions.create(
    model="qwen2.5-0.5b-instruct",
    messages=[
        {"role": "system", "content": "You are a concise assistant."},
        {"role": "user", "content": "Explain AWS Lambda in one sentence."},
    ],
    max_tokens=128,
    temperature=0.7,
)
print(resp.choices[0].message.content)

# Streaming works too:
for chunk in client.chat.completions.create(
    model="qwen2.5-0.5b-instruct",
    messages=[{"role": "user", "content": "Write a haiku about clouds."}],
    stream=True,
):
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```

Or with curl:

```bash
curl "$BASE_URL/chat/completions" \
  -H "Authorization: Bearer sk-choose-a-secret" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen2.5-0.5b-instruct", "messages": [{"role": "user", "content": "Hi!"}], "max_tokens": 64}'
```

## Run and test locally

The tests drive the real `llama_cpp.server` (started through `src/run.sh`, the
same entry point Lambda uses) with the official OpenAI SDK.

```bash
python -m venv .venv && . .venv/bin/activate
CMAKE_ARGS="-DGGML_OPENMP=OFF" pip install -r requirements-dev.txt

# Fast: starts the server on a tiny random-weight GGUF generated on the fly
# (output is gibberish, but every request/response path is exercised).
pytest -q

# Real model:
MODEL_PATH=qwen.gguf pytest -q

# Run the server by hand:
MODEL=qwen.gguf API_KEY=test-key src/run.sh   # serves http://localhost:8080/v1

# Against the deployed function:
BASE_URL=https://abc123.lambda-url.us-east-1.on.aws/v1 OPENAI_API_KEY=sk-choose-a-secret pytest -q
```

## Limits and expectations

These are estimates; they haven't been measured on a live deployment yet.

- **Cold start.** Lambda starts the runtime, downloads ~0.4 GB from S3 into
  `/tmp`, and loads the model: expect a few seconds (roughly 3 to 8 s).
  Warm requests skip all of that. A sandbox stays warm for some minutes after
  its last request.
- **Speed.** At 4096 MB, expect roughly 20 to 40 tokens/s, so a 150-token
  answer takes a few seconds. More memory means more vCPUs and faster tokens.
- **One request at a time per instance.** Concurrent callers get separate
  Lambda instances, each with its own cold start.
- **Quality.** A 0.5B model is fine for short chat, rewriting, simple
  classification and extraction, but it makes things up easily, loses track
  in long conversations, and is weak at reasoning and maths. Swap in a bigger
  GGUF (see above) when that matters.
- **Cost.** At 4096 MB you pay about $0.000067 per second of execution
  (us-east-1 x86), so a 3-second answer is about $0.0002. Idle costs nothing
  except S3 storage for the model (about a cent a month). No ECR.
- **Not supported by the server:** `n > 1` and image inputs. Tool calling and
  JSON mode depend on llama-cpp-python's support for the model's chat format.
