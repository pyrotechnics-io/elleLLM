# SAM "makefile" build for LlmFunction: dependencies + entry point + model,
# all inside the zip. Lambda's limit is 250 MB unzipped.
MODEL_URL ?= https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q8_0.gguf
PYTHON ?= python3
LIMIT_BYTES := 262144000
LLAMA_CPP_PYTHON := $(shell sed -n 's/^llama-cpp-python\[server\]==//p' requirements.txt)

# Generic x86_64 with AVX2 rather than the build machine's CPU; no OpenMP
# because the Lambda runtime lacks libgomp.
export CMAKE_ARGS ?= -DGGML_NATIVE=OFF -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_OPENMP=OFF

build-LlmFunction:
	# llama.cpp is compiled here. Python loads it through ctypes, so the result
	# doesn't depend on the build host's Python version.
	$(PYTHON) -m pip install --no-cache-dir --no-compile --no-deps \
		--target "$(ARTIFACTS_DIR)" "llama-cpp-python==$(LLAMA_CPP_PYTHON)"
	# Everything else: wheels for the Lambda runtime (Python 3.12, x86_64),
	# whatever Python this build runs on.
	$(PYTHON) -m pip install --no-cache-dir --no-compile \
		--target "$(ARTIFACTS_DIR)" --platform manylinux2014_x86_64 \
		--python-version 3.12 --only-binary=:all: -r lambda-deps.txt
	cp run.sh "$(ARTIFACTS_DIR)/"
	$(PYTHON) -c 'import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])' \
		"$(MODEL_URL)" "$(ARTIFACTS_DIR)/model.gguf"
	# Trim what the server never loads, to stay under the size limit.
	rm -rf "$(ARTIFACTS_DIR)/bin" "$(ARTIFACTS_DIR)/include"
	find "$(ARTIFACTS_DIR)" -type d \( -name __pycache__ -o -name tests \) -prune -exec rm -rf {} +
	# Guard: a Python extension built for another version crashes the function
	# at startup (Runtime.ExitError), so fail the build instead.
	@bad=$$(find "$(ARTIFACTS_DIR)" -name '*.cpython-*.so' ! -name '*.cpython-312-*'); \
	if [ -n "$$bad" ]; then echo "extension modules not built for Python 3.12:" >&2; echo "$$bad" >&2; exit 1; fi
	@size=$$(du -sb "$(ARTIFACTS_DIR)" | cut -f1); \
	echo "package size: $$((size / 1048576)) MB (limit 250 MB)"; \
	if [ $$size -gt $(LIMIT_BYTES) ]; then echo "package exceeds Lambda's 250 MB limit; use a smaller MODEL_URL" >&2; exit 1; fi
