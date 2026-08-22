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

# Real-provider CLI contract tests; loads .env.test when present.
eval:
    if [ -f .env.test ]; then set -a; source .env.test; set +a; fi; moon cram test tests/live
