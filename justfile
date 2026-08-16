set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

check:
    moon check --deny-warn

build:
    moon build --target native

test:
    moon test
    just cram

cram:
    moon cram test tests/cram
