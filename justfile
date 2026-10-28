set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

default:
    @just --list

check:
    moon check --deny-warn

fmt:
    moon fmt
    moon info

build:
    moon build

test:
    moon test
    just cram

# Build dist/pim.js, the npm dist of the root package (see scripts/pack-npm.sh).
package:
    bash scripts/pack-npm.sh

# Replay the offline fixture and regenerate the README TUI image.
screenshot:
    python3 scripts/screenshot/capture.py

cram:
    moon build
    moon cram test --work-directory . tests/cram

eval:
    moon build --target js && moon cram test --work-directory . tests/live
