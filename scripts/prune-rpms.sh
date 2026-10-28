#!/bin/bash
# Delete older RPM versions and keep the newest build of each package.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if ! command -v rpm >/dev/null 2>&1; then
  echo "rpm is required to prune packages." >&2
  exit 1
fi

vercmp() {
  local left=$1
  local right=$2
  rpm --eval "%{lua:print(rpm.vercmp([[${left}]], [[${right}]]))}"
}

compare_evr() {
  local epoch_a=$1 version_a=$2 release_a=$3
  local epoch_b=$4 version_b=$5 release_b=$6
  local result
  result=$(vercmp "$epoch_a" "$epoch_b")
  if [[ "$result" -ne 0 ]]; then
    printf '%s\n' "$result"
    return
  fi
  result=$(vercmp "$version_a" "$version_b")
  if [[ "$result" -ne 0 ]]; then
    printf '%s\n' "$result"
    return
  fi
  vercmp "$release_a" "$release_b"
}

shopt -s nullglob
mapfile -d '' rpm_files < <(find packages -type f -name '*.rpm' -print0)
if [[ ${#rpm_files[@]} -eq 0 ]]; then
  echo "No packages to prune."
  exit 0
fi

declare -A best_epoch best_version best_release
declare -a records=()

for rpm_file in "${rpm_files[@]}"; do
  name=$(rpm -qp --nosignature --qf '%{NAME}' "$rpm_file")
  epoch=$(rpm -qp --nosignature --qf '%{EPOCHNUM}' "$rpm_file")
  version=$(rpm -qp --nosignature --qf '%{VERSION}' "$rpm_file")
  release=$(rpm -qp --nosignature --qf '%{RELEASE}' "$rpm_file")
  sourcepackage=$(rpm -qp --nosignature --qf '%{SOURCEPACKAGE}' "$rpm_file")
  release=$(printf '%s' "$release" | sed -E 's/\.fc[0-9]+$//')
  key="${name}|${sourcepackage}"
  records+=("${key}"$'\t'"${epoch}"$'\t'"${version}"$'\t'"${release}"$'\t'"${rpm_file}")
  if [[ -z "${best_version[$key]+x}" ]]; then
    best_epoch[$key]=$epoch
    best_version[$key]=$version
    best_release[$key]=$release
    continue
  fi
  result=$(compare_evr "$epoch" "$version" "$release" "${best_epoch[$key]}" "${best_version[$key]}" "${best_release[$key]}")
  if [[ "$result" -gt 0 ]]; then
    best_epoch[$key]=$epoch
    best_version[$key]=$version
    best_release[$key]=$release
  fi
done

removed=0
for record in "${records[@]}"; do
  IFS=$'\t' read -r key epoch version release rpm_file <<< "$record"
  result=$(compare_evr "$epoch" "$version" "$release" "${best_epoch[$key]}" "${best_version[$key]}" "${best_release[$key]}")
  if [[ "$result" -lt 0 ]]; then
    rm -f -- "$rpm_file"
    echo "removed ${rpm_file#"$root"/}"
    removed=$((removed + 1))
  fi
done

echo "removed ${removed}"
