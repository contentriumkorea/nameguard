#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
export MACOSX_DEPLOYMENT_TARGET=13.0
cargo build --release --locked
cp target/release/nameguard .build/nameguard
echo "Built: $PWD/.build/nameguard"
