#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
cargo test --locked -- --test-threads=1
/usr/bin/python3 Tests/integration.py
