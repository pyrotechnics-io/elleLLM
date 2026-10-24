# elleLLM

A small conversational model running **entirely inside one AWS Lambda function**,
exposed as an **OpenAI-compatible** Chat Completions API. No GPU, no external
inference service, no container image, no ECR and no S3: it's a single zip on
the managed `python3.12` runtime with the model file inside it.

- **Model:** [SmolLM2-135M-Instruct](https://huggingface.co/HuggingFaceTB/SmolLM2-135M-Instruct)
  by Hugging Face, 8-bit `Q8_0` GGUF (~145 MB), Apache-2.0.
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
                                         model.gguf (in the zip)
```

`sam build` runs `src/Makefile`, which installs the Python dependencies, copies
`run.sh`, and downloads the model into the package. Lambda's limit for a zip is
250 MB unzipped; this package is about 215 MB (≈70 MB of dependencies + 145 MB
model), and the build fails with a clear message if a model would push it over.

## Why SmolLM2-135M

It's the most capable chat model that fits inside a Lambda zip next to the
inference library, so the function stays self-contained, light and fast. The
8-bit quantization is used rather than 4-bit because very small models lose
noticeably more quality when quantized hard, and there's room for it.

What to expect from it: fine for rephrasing short text, extracting a field,
or answering yes/no and category questions with a tight prompt. It can't do
arithmetic, gets facts wrong often, and drifts after a few sentences or a
couple of chat turns. For better answers you'd need a model that no longer
fits in a zip (e.g. Qwen2.5-0.5B at ~0.4 GB), which means loading it from S3 at
cold start or using a container image.

## Endpoints

| Method | Path                    | Notes                                   |
|--------|-------------------------|-----------------------------------------|
| POST   | `/v1/chat/completions`  | `model`, `messages`, `max_tokens`, `temperature`, `top_p`, `stop`, `stream` (default `false`), etc. |
| POST   | `/v1/completions`       | Legacy text completions                 |
| GET    | `/v1/models`            | Returns `smollm2-135m-instruct`         |

## Shortcuts (Makefile)

```bash
echo 'API_KEY=<a long random string>' > .env   # once; .env is gitignored
make deploy      # build, check the package, deploy, print the base_url
make test        # run the tests against the deployed endpoint
make ask Q='Hello there'   # one chat message
make logs        # last 30 minutes of Lambda logs
make help        # everything else (NO_DOCKER=1, STACK=..., REGION=..., MEMORY=...)
```

`make deploy` refuses to deploy unless the build produced a complete package.
The manual `sam` commands are below.

## Deploy

Prerequisites: AWS CLI with credentials, [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html),
and Docker (only used by `sam build` to compile llama.cpp inside the Lambda
build image so the binary matches the runtime; nothing is pushed anywhere).

```bash
sam build                      # builds in the Lambda build image (see samconfig.toml)
sam deploy --guided --parameter-overrides ApiKey=sk-choose-a-secret
```

**AWS CloudShell** (no Docker): install the compiler tools and build without a
container. The Makefile fetches dependency wheels for the Lambda runtime's
Python 3.12 whatever Python CloudShell has, and fails the build if a
wrongly-built extension slips in.

```bash
sudo dnf install -y cmake gcc-c++ git
sam build --no-use-container
sam deploy --guided --parameter-overrides ApiKey=<a long random string>
```

The deploy prints `BaseUrl`, something like
`https://abc123.lambda-url.us-east-1.on.aws/v1`.

To bundle a different GGUF that still fits, override the download URL:
`MODEL_URL=https://...gguf sam build --no-use-container`, or
`sam build --container-env-var MODEL_URL=https://...gguf` when building in the
container.

Parameters:

| Parameter     | Default | Meaning |
|---------------|---------|---------|
| `ApiKey`      | empty   | Bearer token clients must send. Empty means the URL is open to anyone. **Set one.** |
| `ModelAlias`  | `smollm2-135m-instruct` | Model id reported by `/v1/models`. |
| `MemorySize`  | `2048`  | MB; also sets vCPUs (≈1.2 at 2048) and therefore speed. |
| `ContextSize` | `4096`  | Prompt + completion tokens (the model supports up to 8192). |
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
    model="smollm2-135m-instruct",
    messages=[
        {"role": "system", "content": "You are a concise assistant."},
        {"role": "user", "content": "Rewrite politely: send me the report now."},
    ],
    max_tokens=128,
    temperature=0.3,
)
print(resp.choices[0].message.content)

# Streaming works too:
for chunk in client.chat.completions.create(
    model="smollm2-135m-instruct",
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
  -d '{"model": "smollm2-135m-instruct", "messages": [{"role": "user", "content": "Hi!"}], "max_tokens": 64}'
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
curl -L -o smol.gguf https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q8_0.gguf
MODEL_PATH=smol.gguf pytest -q

# Run the server by hand:
MODEL=smol.gguf API_KEY=test-key src/run.sh   # serves http://localhost:8080/v1

# Against the deployed function:
BASE_URL=https://abc123.lambda-url.us-east-1.on.aws/v1 OPENAI_API_KEY=sk-choose-a-secret pytest -q
```

## Limits and expectations

These are estimates; they haven't been measured on a live deployment yet.

- **Cold start.** Lambda loads the ~215 MB package, starts Python and maps the
  model: expect roughly 2 to 4 seconds. Warm requests skip this.
- **Speed.** A 135M model is light; at 2048 MB expect very roughly 50+ tokens/s,
  so most answers come back in a second or two.
- **One request at a time per instance.** Concurrent callers get separate
  Lambda instances, each with its own cold start.
- **Quality.** See "Why SmolLM2-135M" above. Keep prompts short and specific
  and use a low `temperature`.
- **Cost.** At 2048 MB you pay about $0.000033 per second of execution
  (us-east-1 x86), so a 1.5-second answer is about $0.00005. Idle costs nothing.
- **Not supported by the server:** `n > 1` and image inputs. Tool calling and
  JSON mode depend on llama-cpp-python's support for the model's chat format.
