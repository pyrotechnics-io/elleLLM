"""Write a tiny random-weight Llama-architecture GGUF for tests.

The output is gibberish, but it lets the OpenAI-compatible server start in a
second and exercises the full request/response path without downloading the
real model.
"""

import string
import sys

import gguf
import numpy as np

N_EMBD = 64
N_FF = 128
N_LAYER = 2
N_HEAD = 4
N_CTX = 512

CHAT_TEMPLATE = (
    "{% for message in messages %}"
    "<|{{ message['role'] }}|>{{ message['content'] }}<|end|>"
    "{% endfor %}"
    "{% if add_generation_prompt %}<|assistant|>{% endif %}"
)


def _vocab():
    tokens = ["<unk>", "<s>", "</s>"]
    types = [gguf.TokenType.UNKNOWN, gguf.TokenType.CONTROL, gguf.TokenType.CONTROL]
    tokens += [f"<0x{i:02X}>" for i in range(256)]
    types += [gguf.TokenType.BYTE] * 256
    pieces = ["▁"] + list(string.ascii_letters + string.digits + string.punctuation)
    pieces += ["▁" + c for c in string.ascii_letters]
    tokens += pieces
    types += [gguf.TokenType.NORMAL] * len(pieces)
    scores = [0.0] * 3 + [0.0] * 256 + [-float(i) for i in range(len(pieces))]
    return tokens, scores, types


def write(path: str) -> None:
    rng = np.random.default_rng(0)
    tokens, scores, types = _vocab()
    n_vocab = len(tokens)

    w = gguf.GGUFWriter(path, "llama")
    w.add_name("tiny-test-llama")
    w.add_context_length(N_CTX)
    w.add_embedding_length(N_EMBD)
    w.add_block_count(N_LAYER)
    w.add_feed_forward_length(N_FF)
    w.add_rope_dimension_count(N_EMBD // N_HEAD)
    w.add_head_count(N_HEAD)
    w.add_head_count_kv(N_HEAD)
    w.add_layer_norm_rms_eps(1e-5)
    w.add_file_type(gguf.LlamaFileType.ALL_F32)

    w.add_tokenizer_model("llama")
    w.add_token_list(tokens)
    w.add_token_scores(scores)
    w.add_token_types(types)
    w.add_bos_token_id(1)
    w.add_eos_token_id(2)
    w.add_unk_token_id(0)
    w.add_add_bos_token(True)
    w.add_chat_template(CHAT_TEMPLATE)

    def t(name, *shape):
        w.add_tensor(name, (rng.standard_normal(shape) * 0.02).astype(np.float32))

    t("token_embd.weight", n_vocab, N_EMBD)
    w.add_tensor("output_norm.weight", np.ones(N_EMBD, dtype=np.float32))
    t("output.weight", n_vocab, N_EMBD)
    for i in range(N_LAYER):
        w.add_tensor(f"blk.{i}.attn_norm.weight", np.ones(N_EMBD, dtype=np.float32))
        w.add_tensor(f"blk.{i}.ffn_norm.weight", np.ones(N_EMBD, dtype=np.float32))
        for n in ("attn_q", "attn_k", "attn_v", "attn_output"):
            t(f"blk.{i}.{n}.weight", N_EMBD, N_EMBD)
        t(f"blk.{i}.ffn_gate.weight", N_FF, N_EMBD)
        t(f"blk.{i}.ffn_up.weight", N_FF, N_EMBD)
        t(f"blk.{i}.ffn_down.weight", N_EMBD, N_FF)

    w.write_header_to_file()
    w.write_kv_data_to_file()
    w.write_tensors_to_file()
    w.close()


if __name__ == "__main__":
    write(sys.argv[1] if len(sys.argv) > 1 else "tiny.gguf")
