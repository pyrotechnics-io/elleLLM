# Day-to-day commands. Run `make help` for the list.
#
#   make deploy API_KEY=<secret>     build + deploy + print the endpoint
#   make test                        run the test suite against the deployed endpoint
#
# Put API_KEY=... in a .env file (gitignored) to stop typing it.

-include .env

STACK   ?= ellellm
REGION  ?= $(or $(AWS_REGION),$(AWS_DEFAULT_REGION),ap-southeast-1)
MEMORY  ?= 2048
VENV    ?= .venv
Q       ?= Say hi in five words.

# Build in the Lambda build image (needs Docker). NO_DOCKER=1 builds on this
# machine instead (needs cmake and a C++ compiler; Linux only).
SAM_BUILD_FLAGS := $(if $(NO_DOCKER),--no-use-container)
BUILD_DIR := .aws-sam/build/LlmFunction

# Endpoint of the deployed stack; override to test something else, e.g.
#   make test BASE_URL=http://localhost:8080/v1
BASE_URL ?= $(shell $(MAKE) --no-print-directory -s url)

.PHONY: help build check-build deploy test test-local url ask logs stack clean check-key

help:
	@echo "make build            build the Lambda package (NO_DOCKER=1 to build without Docker)"
	@echo "make deploy           build, deploy, and print the endpoint (needs API_KEY)"
	@echo "make test             run the tests against the deployed endpoint (needs API_KEY)"
	@echo "make test-local       run the tests against a local server (tiny test model)"
	@echo "make url              print the OpenAI base_url of the deployed stack"
	@echo "make ask Q='...'      send one chat message to the deployed endpoint"
	@echo "make logs             show the last 30 minutes of Lambda logs"
	@echo "make stack            print the name of an existing elleLLM stack in this region"
	@echo "make clean            delete the local build output"
	@echo
	@echo "Settings: STACK=$(STACK) REGION=$(REGION) MEMORY=$(MEMORY)"

check-key:
	@test -n "$(API_KEY)" || { echo "Set API_KEY: make $(MAKECMDGOALS) API_KEY=<secret>  (or put API_KEY=... in .env)" >&2; exit 1; }

build:
	sam build $(SAM_BUILD_FLAGS)
	@$(MAKE) --no-print-directory check-build

# Deploying without a good build uploads the raw source folder and the function
# then fails at startup, so refuse to continue unless the package is complete.
check-build:
	@test -d $(BUILD_DIR)/llama_cpp && test -f $(BUILD_DIR)/model.gguf && test -f $(BUILD_DIR)/run.sh \
		|| { echo "$(BUILD_DIR) is missing llama_cpp, model.gguf or run.sh: run 'make build' first" >&2; exit 1; }
	@echo "build ok: $$(du -sm $(BUILD_DIR) | cut -f1) MB"

deploy: check-key build
	sam deploy --template-file .aws-sam/build/template.yaml \
		--stack-name $(STACK) --region $(REGION) \
		--capabilities CAPABILITY_IAM --resolve-s3 \
		--no-confirm-changeset --no-fail-on-empty-changeset \
		--parameter-overrides ApiKey=$(API_KEY) MemorySize=$(MEMORY)
	@echo
	@echo "base_url: $$($(MAKE) --no-print-directory -s url)"

url:
	@aws cloudformation describe-stacks --region $(REGION) --stack-name $(STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='BaseUrl'].OutputValue" --output text

# Tests against the deployed function. Needs only pytest, openai and requests.
$(VENV)/bin/pytest:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q pytest openai requests

test: check-key $(VENV)/bin/pytest
	@test -n "$(BASE_URL)" || { echo "No endpoint: is stack $(STACK) deployed in $(REGION)? (make stack)" >&2; exit 1; }
	BASE_URL="$(BASE_URL)" OPENAI_API_KEY="$(API_KEY)" $(VENV)/bin/pytest -q tests

# Tests against a local server on a tiny generated model (compiles llama.cpp).
$(VENV)/.dev-installed:
	python3 -m venv $(VENV)
	CMAKE_ARGS="-DGGML_OPENMP=OFF" $(VENV)/bin/pip install -q -r requirements-dev.txt
	touch $@

test-local: $(VENV)/.dev-installed
	$(VENV)/bin/pytest -q tests

ask: check-key
	@curl -sS "$(BASE_URL)/chat/completions" \
		-H "Authorization: Bearer $(API_KEY)" -H "Content-Type: application/json" \
		-d '{"model":"smollm2-135m-instruct","messages":[{"role":"user","content":"$(Q)"}],"max_tokens":128}'
	@echo

logs:
	aws logs tail /aws/lambda/$$(aws cloudformation describe-stack-resource --region $(REGION) \
		--stack-name $(STACK) --logical-resource-id LlmFunction \
		--query StackResourceDetail.PhysicalResourceId --output text) --region $(REGION) --since 30m

stack:
	@aws lambda list-functions --region $(REGION) \
		--query "Functions[?contains(FunctionName,'-LlmFunction-')].FunctionName" --output text \
		| sed 's/-LlmFunction-.*//'

clean:
	rm -rf .aws-sam
