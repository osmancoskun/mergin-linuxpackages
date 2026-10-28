#!/bin/bash
# Move incoming/*.rpm into packages/fedora/<version>/<arch>/ using RPM metadata.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if ! command -v rpm >/dev/null 2>&1; then
  echo "rpm is required to place packages." >&2
  exit 1
fi

shopt -s nullglob
rpms=("$root"/incoming/*.rpm)
if [[ ${#rpms[@]} -eq 0 ]]; then
  echo "No incoming RPM files."
  exit 0
fi

for rpm in "${rpms[@]}"; do
  arch=$(rpm -qp --nosignature --qf '%{ARCH}' "$rpm")
  release=$(rpm -qp --nosignature --qf '%{RELEASE}' "$rpm")
  sourcepackage=$(rpm -qp --nosignature --qf '%{SOURCEPACKAGE}' "$rpm")
  if [[ ! "$release" =~ fc([0-9]+) ]]; then
    echo "RPM has no Fedora dist tag: $rpm (release $release)" >&2
    exit 1
  fi
  fedora="${BASH_REMATCH[1]}"
  if [[ "$sourcepackage" == "1" ]]; then
    dest="packages/fedora/${fedora}/SRPMS"
  else
    dest="packages/fedora/${fedora}/${arch}"
  fi
  mkdir -p \
    "packages/fedora/${fedora}/x86_64" \
    "packages/fedora/${fedora}/aarch64" \
    "$dest"
  touch \
    "packages/fedora/${fedora}/x86_64/.gitkeep" \
    "packages/fedora/${fedora}/aarch64/.gitkeep"
  cp -a "$rpm" "$dest/$(basename "$rpm")"
  echo "placed $dest/$(basename "$rpm")"
done
