import os
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest
import requests

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

API_KEY = os.environ.get("OPENAI_API_KEY", "test-key")


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_ready(base_url: str, proc: subprocess.Popen | None, timeout: float) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc is not None and proc.poll() is not None:
            raise RuntimeError(f"server exited early:\n{proc.stdout.read()}")
        try:
            r = requests.get(f"{base_url}/models", headers={"Authorization": f"Bearer {API_KEY}"}, timeout=2)
            if r.status_code == 200:
                return
        except requests.ConnectionError:
            pass
        time.sleep(0.5)
    raise TimeoutError(f"server at {base_url} not ready after {timeout}s")


@pytest.fixture(scope="session")
def base_url(tmp_path_factory):
    """OpenAI base_url of the server under test.

    - BASE_URL set: test an already-running server (e.g. the Docker image, or
      the deployed Function URL).
    - MODEL_PATH set: start the server locally on that GGUF (e.g. SmolLM2-135M).
    - otherwise: start the server on a tiny random GGUF built on the fly.
    """
    if os.environ.get("BASE_URL"):
        url = os.environ["BASE_URL"].rstrip("/")
        _wait_ready(url, None, timeout=600)
        yield url
        return

    model = os.environ.get("MODEL_PATH")
    if not model:
        import tiny_gguf

        model = str(tmp_path_factory.mktemp("model") / "tiny.gguf")
        tiny_gguf.write(model)

    port = _free_port()
    env = {
        **os.environ,
        "MODEL": model,
        "MODEL_ALIAS": "smollm2-135m-instruct",
        "HOST": "127.0.0.1",
        "PORT": str(port),
        "N_CTX": "512",
        "API_KEY": API_KEY,
    }
    proc = subprocess.Popen(
        [str(ROOT / "src" / "run.sh")],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    url = f"http://127.0.0.1:{port}/v1"
    try:
        _wait_ready(url, proc, timeout=300)
        yield url
    finally:
        proc.terminate()
        proc.wait(timeout=30)


@pytest.fixture(scope="session")
def client(base_url):
    from openai import OpenAI

    return OpenAI(base_url=base_url, api_key=API_KEY)
