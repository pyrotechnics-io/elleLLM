# elleLLM

<img width="1376" height="768" alt="elleLLM" src="https://github.com/user-attachments/assets/71006894-8aed-479e-97a7-f15a851ddd58" />

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
make help        # everything else (USE_DOCKER=1, STACK=..., REGION=..., MEMORY=...)
```

`make deploy` refuses to deploy unless the build produced a complete package.
The build runs on your machine, no Docker needed. `STACK` defaults to
`ellellm`; pass `STACK=<name>` to update a stack that already exists under
another name. The manual `sam` commands are below.

## Deploy

Prerequisites: AWS CLI with credentials, [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html),
`cmake`, a C++ compiler, [`uv`](https://docs.astral.sh/uv/) (or `python3 -m venv`), and
[`zig`](https://ziglang.org/download/).

`make build` compiles llama.cpp with `zig cc` targeting glibc 2.34. A plain
host compiler links against your distro's newer glibc/libstdc++, and the
function then dies at startup on Lambda's older runtime (for example
`GLIBC_2.43 not found`). After the build, `make check-build` fails if any
library needs a newer glibc, `libstdc++` or `libgomp` than Lambda has, so a
bad package can't be deployed.

```bash
make build                     # host build with zig; USE_DOCKER=1 uses the Lambda build image
make deploy API_KEY=sk-choose-a-secret
```

Docker still works (`make build USE_DOCKER=1`, or `sam build --use-container`)
and is the way to build on macOS or Windows.

**AWS CloudShell** (Amazon Linux 2023, same glibc as Lambda, so no zig needed):
build with the system compiler, no container. The Makefile fetches dependency
wheels for the Lambda runtime's Python 3.12 whatever Python CloudShell has, and
fails the build if a wrongly-built extension slips in.

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

## Getting good results from a 135M model

A model this small ignores instructions and follows patterns. Everything below
was measured against the deployed endpoint (temperature 0); sample sizes are
small (10 to 60 items per test), so read the numbers as rough.

**What it can do**

| Task | How | Result |
|------|-----|--------|
| Sentiment (3 classes, 60 items) | 8 shuffled examples per class + calibration | 88% mean (83 to 95% over 5 orderings) |
| Extract fields to JSON (10 items) | 3 examples + `response_format` schema | 100% of fields (67% with no examples) |
| Answer from a given passage (10 items) | zero-shot, plain question | 90% |
| Summarize 3 to 4 sentences | 2 examples | Faithful, but mostly lifts sentences from the source |
| Intent, 4 classes (12 items) | 4 examples per class | 50% (chance is 25%), mediocre |
| Yes/no from a passage (10 items) | 2 to 4 examples | 70%, but it answers "no" about 8 times in 10 |
| Polite rewrite | 3 examples | Sometimes fine, sometimes refuses or flips the meaning |
| Translation, arithmetic, code | any | Don't. Output is nonsense |

**Rules that made the difference**

1. **Show examples, don't just describe the task.** Put them in the
   conversation as alternating `user` / `assistant` turns. A system prompt alone,
   even with label definitions, scored 0 to 3% on sentiment because the model
   answers like a support bot ("I'm sorry for the inconvenience") instead of
   following "reply with one word".
2. **Shuffle the examples; never group them by class.** The model copies the
   label of the last examples it saw. With grouped examples it answered one class
   for almost every input (33% on 3 classes). Interleaved or shuffled fixed
   orders reached 70 to 95%. Order alone moved accuracy by up to 15 points, so
   test a few shuffles and keep the best fixed one.
3. **Use more examples per class.** Sentiment mean accuracy over 5 shuffles
   (calibrated): 3 per class 77%, 5 per class 84%, 8 per class 88%, and the worst
   ordering improved from 72% to 83%. Prompts of a few hundred tokens are still
   fast (about 0.4 s).
4. **Constrain the output.** Don't parse free text.
   - Labels: `extra_body={"grammar": 'root ::= "positive" | "negative" | "neutral"'}`.
     Leave `max_tokens` at 12 or more, because labels span several tokens and
     get cut off otherwise (`"negativ"`).
   - JSON: `response_format={"type": "json_object", "schema": {...}}` always
     returns valid JSON matching the schema.
5. **Use `temperature=0`** for classification and extraction.
6. **Don't cap `max_tokens` tightly on free text.** A cap cut `$799` to `$79` in
   a summary, and the result still looked like a finished sentence. Let the
   answer finish, or use `stop`.
7. **One short task per call.** Keep inputs to a few sentences, and don't ask for
   several things at once.
8. **Verify numbers in code.** In summaries and extractions the model sometimes
   swaps or changes digits (a party size of 3 for 2, "begin by June" for "finish
   by June"). Check that every number in the output appears in the input.
9. **Terse-answer prompts can backfire.** "Answer in as few words as possible"
   dropped passage QA from 90% to 70%. Plain sentences are more accurate; trim
   them in code.

**Classifying with probabilities (most stable)**

Picking the label from token probabilities, after dividing out the model's bias
on content-free input, was the most stable method. With the examples in place:

```python
import math
LABELS = ["positive", "negative", "neutral"]

def label_probs(messages):
    r = client.chat.completions.create(
        model="smollm2-135m-instruct", messages=messages, temperature=0,
        max_tokens=1, logprobs=True, top_logprobs=30)
    p = dict.fromkeys(LABELS, 0.0)
    for t in r.choices[0].logprobs.content[0].top_logprobs:
        tok = t.token.strip().lower()
        for label in LABELS:
            if len(tok) >= 3 and (label.startswith(tok) or tok.startswith(label)):
                p[label] += math.exp(t.logprob)
    return p

def build(text):  # system prompt + shuffled few-shot turns + the text to classify
    ...

# Calibrate once: how much does the model favour each label for an empty input?
cal = {l: 0.0 for l in LABELS}
for blank in ("N/A", " ", "[MASK]"):
    for l, v in label_probs(build(blank)).items():
        cal[l] += max(v, 1e-6) / 3

def classify(text):
    p = label_probs(build(text))
    return max(LABELS, key=lambda l: p[l] / cal[l])
```

Calibration was a small, noisy gain over plain grammar-constrained generation
(with 5 examples per class: 84% vs 82% mean over 5 orderings; its best single
ordering reached 93% but another only 78%). It costs three extra requests once
plus slightly more time per call. Skip it if the simpler method is accurate
enough for you; the examples and their order matter more.

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

Measured on a deployed function (2048 MB, ap-southeast-1) unless noted.

- **Cold start.** The first request after idle took about 7 seconds, measured
  end to end from a laptop with client overhead included (one sample; the true
  figure may be a bit lower). Warm requests skip this.
- **Speed.** Warm requests with a one-word answer take 0.25 to 0.35 s; 40 to
  60 token answers take about 0.7 to 1.5 s. Adding a few hundred tokens of
  examples to the prompt raises a one-word answer to about 0.4 s. Occasional
  outliers reached 2 s.
- **One request at a time per instance.** Concurrent callers get separate
  Lambda instances, each with its own cold start.
- **Quality.** See "Why SmolLM2-135M" above and "Getting good results" for what
  it can and cannot do. Keep prompts short and specific and use `temperature` 0.
- **Cost.** At 2048 MB you pay about $0.000033 per second of execution
  (us-east-1 x86), so a 1.5-second answer is about $0.00005. Idle costs nothing.
- **Not supported by the server:** `n > 1` and image inputs. Tool calling
  depends on llama-cpp-python's support for the model's chat format and hasn't
  been tested. JSON schema output (`response_format`), `grammar`, `logprobs`,
  `stop` and streaming work (tested through the OpenAI SDK).
