# elleLLM

A small conversational model running **entirely inside one AWS Lambda function**,
exposed as an **OpenAI-compatible** Chat Completions API. No GPUs, no external
inference service: the model weights ship inside the Lambda container image.

- **Model:** [Microsoft Phi-4-mini-instruct](https://huggingface.co/microsoft/Phi-4-mini-instruct)
  (3.8B parameters), 4-bit `Q4_K_M` GGUF quantization (~2.5 GB) from
  [bartowski/microsoft_Phi-4-mini-instruct-GGUF](https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF).
- **Runtime:** [llama-cpp-python](https://github.com/abetlen/llama-cpp-python) and its
  built-in OpenAI-compatible server (`python -m llama_cpp.server`). There is no
  hand-written API code: request/response shapes, streaming and auth all come
  from that library.
- **Glue:** [AWS Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter)
  runs the HTTP server inside Lambda and forwards Function URL requests to it,
  with response streaming enabled.
- **IaC:** AWS SAM (`template.yaml`).

## Why Phi-4-mini, and these settings

Phi-4-mini is the smallest current Phi model and is strong at chat and
reasoning for its size. At 4-bit it needs ~2.5 GB of weights plus a little
KV cache, which fits easily inside Lambda's 10 GB memory and 10 GB container
image limits. Lambda allocates vCPUs in proportion to memory, and token speed
on CPU scales with cores, so the function defaults to the maximum **10240 MB
(6 vCPUs)** and uses all of them for inference.

The API is served from a **Lambda Function URL**, not API Gateway, because API
Gateway caps requests at 29 seconds and a CPU-bound 3.8B model can take longer
than that for long answers. The function timeout is 300 s.

To use a different GGUF (for example `Phi-3.5-mini-instruct` or a smaller
quantization like `Q3_K_M`), pass `--build-arg MODEL_URL=...` when building.

## Endpoints

| Method | Path                    | Notes                                   |
|--------|-------------------------|-----------------------------------------|
| POST   | `/v1/chat/completions`  | `model`, `messages`, `max_tokens`, `temperature`, `top_p`, `stop`, `stream` (default `false`), etc. |
| POST   | `/v1/completions`       | Legacy text completions                 |
| GET    | `/v1/models`            | Returns `phi-4-mini`                    |

## Deploy

Prerequisites: AWS CLI with credentials, [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html),
and Docker. Build on an x86_64 machine (or with x86_64 emulation); the first
build compiles llama.cpp and downloads ~2.5 GB, so it takes several minutes.

```bash
sam build
sam deploy --guided \
  --parameter-overrides ApiKey=sk-choose-a-secret
```

`--guided` asks for a stack name and region and offers to create an ECR repository
for the image. When it finishes it prints `BaseUrl`, something like
`https://abc123.lambda-url.us-east-1.on.aws/v1`.

Parameters:

| Parameter     | Default | Meaning |
|---------------|---------|---------|
| `ApiKey`      | empty   | Bearer token clients must send. Empty means the URL is open to anyone. **Set one.** |
| `MemorySize`  | `10240` | MB; also controls vCPUs and therefore speed. |
| `ContextSize` | `4096`  | Prompt + completion tokens. Larger costs more memory and slower prompts. |

## Call it with the OpenAI SDK

Just change `base_url` (and use your `ApiKey`):

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://abc123.lambda-url.us-east-1.on.aws/v1",
    api_key="sk-choose-a-secret",
)

resp = client.chat.completions.create(
    model="phi-4-mini",
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
    model="phi-4-mini",
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
  -d '{"model": "phi-4-mini", "messages": [{"role": "user", "content": "Hi!"}], "max_tokens": 64}'
```

## Run and test locally

The tests use the real OpenAI SDK against the real `llama_cpp.server`.

```bash
python -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt

# Fast: starts the server on a tiny random-weight GGUF generated on the fly
# (output is gibberish, but every request/response path is exercised).
pytest -q

# Real model: download the Phi-4-mini GGUF and point the tests at it.
curl -L -o models/phi-4-mini.gguf --create-dirs \
  https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/main/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf
MODEL_PATH=models/phi-4-mini.gguf pytest -q

# The actual Lambda image, run locally (outside Lambda the web adapter isn't
# started, so the server just listens on port 8080):
docker build -t ellellm .
docker run --rm -p 8080:8080 -e API_KEY=test-key ellellm
BASE_URL=http://localhost:8080/v1 pytest -q

# Or the deployed function:
BASE_URL=https://abc123.lambda-url.us-east-1.on.aws/v1 OPENAI_API_KEY=sk-choose-a-secret pytest -q
```

## Limits and expectations

- **Cold start.** A new Lambda instance has to pull a ~3 GB image and map the
  model into memory before the first token. Expect roughly 10 to 30 seconds on
  a cold start (Lambda caches image layers, so repeat cold starts are faster);
  warm requests skip this entirely. If cold starts matter, add provisioned
  concurrency, which keeps instances warm at an hourly cost.
- **Speed.** This is a 3.8B model on 6 CPU cores. Expect single-digit to low
  double-digit tokens per second, so a 200-token answer can take 15 to 40
  seconds. Use `stream: true` so users see tokens as they arrive.
- **One request at a time per instance.** Lambda sends one request per
  instance; concurrent callers get separate instances, each with its own cold
  start.
- **Quality.** Phi-4-mini is good for its size at chat, summarisation, and
  simple reasoning, but it is far below frontier models, has limited world
  knowledge, and 4-bit quantization costs a little more accuracy. Don't rely on
  it for facts.
- **Context.** 4096 tokens by default (the model supports much more, but each
  extra token costs memory and prompt-processing time on CPU).
- **Cost.** At 10240 MB you pay about $0.00017 per second of execution
  (us-east-1 x86 pricing), so a 20-second answer costs well under a cent. Idle
  costs nothing beyond ECR storage of the ~3 GB image.
- **Not implemented by the server:** `n > 1`, embeddings for chat models, and
  image inputs. Tool calling and JSON mode depend on llama-cpp-python's support
  for the model's chat format.
