#!/bin/bash
# Build the signed repository locally in a Fedora 44 container.
# Output lands in ./site and is not committed.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

key=.secrets/mergin-signing-key.asc
pass=.secrets/passphrase
if [[ ! -f $key || ! -f $pass ]]; then
  echo "The signing key is not on this machine. Expected ${key} and ${pass}." >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required to build the repository locally." >&2
  exit 1
fi

exec docker run --rm \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -e GITHUB_REPOSITORY_OWNER="${GITHUB_REPOSITORY_OWNER:-local}" \
  -e GITHUB_REPOSITORY_NAME="${GITHUB_REPOSITORY_NAME:-mergin-linuxpackages}" \
  -e GPG_PRIVATE_KEY_FILE=/run/secrets/mergin-signing-key.asc \
  -e GPG_PASSPHRASE_FILE=/run/secrets/passphrase \
  -v "$PWD:/work" \
  -v "$PWD/.secrets:/run/secrets:ro" \
  -w /work \
  fedora:44 \
  bash scripts/build-repo.sh
