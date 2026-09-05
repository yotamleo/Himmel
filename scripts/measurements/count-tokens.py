#!/usr/bin/env python3
"""HIMMEL-102 token counter - single source of truth across baseline + plugin arms.

Usage: count-tokens.py <file> [<file> ...]
Prints one line per file: "<bytes>\t<tokens>\t<path>"
Then a TOTAL line:        "<sum_bytes>\t<sum_tokens>\tTOTAL"

Uses cl100k_base (Claude/GPT-4-class). Same tokenizer used for both arms so
the delta is internally consistent even if it diverges from the actual
Anthropic tokenizer by a few percent.
"""
import sys
import tiktoken

enc = tiktoken.get_encoding("cl100k_base")
total_bytes = 0
total_tokens = 0
for path in sys.argv[1:]:
    with open(path, "rb") as f:
        data = f.read()
    text = data.decode("utf-8", errors="replace")
    n_tokens = len(enc.encode(text))
    n_bytes = len(data)
    total_bytes += n_bytes
    total_tokens += n_tokens
    print(f"{n_bytes}\t{n_tokens}\t{path}")
print(f"{total_bytes}\t{total_tokens}\tTOTAL")
