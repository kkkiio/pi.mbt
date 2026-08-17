set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

check:
    moon check --deny-warn

fmt:
    moon fmt

build:
    moon build --target native

test:
    moon test
    just cram

cram:
    moon cram test tests/cram

# Real-provider CLI contract tests; requires DEEPSEEK_API_KEY.
eval:
    moon cram test tests/live
