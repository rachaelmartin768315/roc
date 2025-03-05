#!/usr/bin/env bash

# Runs on every Netlify build, to set up the Netlify server.

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -euxo pipefail

# for debugging
cat ./netlify.sh

rustup update
# get Rust version from rust-toolchain.toml
rustup default $(grep "channel =" ../rust-toolchain.toml | head -1 | cut -d '"' -f 2)

bash build.sh
