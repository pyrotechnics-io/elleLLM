# SAM "makefile" build for LlmFunction: dependencies + entry point + model,
# all inside the zip. Lambda's limit is 250 MB unzipped.
MODEL_URL ?= https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q8_0.gguf
LIMIT_BYTES := 262144000

build-LlmFunction:
	pip install --no-compile -r requirements.txt -t "$(ARTIFACTS_DIR)"
	cp run.sh "$(ARTIFACTS_DIR)/"
	python3 -c 'import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])' \
		"$(MODEL_URL)" "$(ARTIFACTS_DIR)/model.gguf"
	# Trim what the server never loads, to stay under the size limit.
	rm -rf "$(ARTIFACTS_DIR)/bin" "$(ARTIFACTS_DIR)/include"
	find "$(ARTIFACTS_DIR)" -type d \( -name __pycache__ -o -name tests \) -prune -exec rm -rf {} +
	@size=$$(du -sb "$(ARTIFACTS_DIR)" | cut -f1); \
	echo "package size: $$((size / 1048576)) MB (limit 250 MB)"; \
	if [ $$size -gt $(LIMIT_BYTES) ]; then echo "package exceeds Lambda's 250 MB limit; use a smaller MODEL_URL" >&2; exit 1; fi
