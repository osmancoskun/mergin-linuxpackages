#!/bin/bash
# Sign RPMs and build the static dnf repository under site/.
# The private key comes from GPG_PRIVATE_KEY / GPG_PRIVATE_KEY_FILE.
# The passphrase comes from GPG_PASSPHRASE / GPG_PASSPHRASE_FILE.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if ! command -v createrepo_c >/dev/null 2>&1 || ! command -v rpmsign >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
  if ! command -v dnf >/dev/null 2>&1; then
    echo "createrepo_c, rpmsign and gpg are required." >&2
    exit 1
  fi
  dnf install -y -q --setopt=install_weak_deps=False createrepo_c rpm-sign gnupg2
fi

owner=${GITHUB_REPOSITORY_OWNER:-}
name=${GITHUB_REPOSITORY_NAME:-}
if [[ -z "$name" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  name=${GITHUB_REPOSITORY#*/}
fi
name=${name:-mergin-linuxpackages}
if [[ -z "$owner" ]]; then
  echo "Set GITHUB_REPOSITORY_OWNER so the published .repo file has a real Pages URL." >&2
  exit 1
fi
owner=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
base="https://${owner}.github.io/${name}"

work=
cleanup() {
  local status=$?
  if [[ -n "$work" ]]; then
    rm -rf "$work"
  fi
  if [[ -n "${HOST_UID:-}" && -n "${HOST_GID:-}" ]]; then
    chown -R "${HOST_UID}:${HOST_GID}" "$root/site" "$root/packages" 2>/dev/null || true
    chown "${HOST_UID}:${HOST_GID}" "$root/README.md" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT

umask 077
work=$(mktemp -d)
export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"
printf 'allow-loopback-pinentry\n' > "$GNUPGHOME/gpg-agent.conf"
printf 'pinentry-mode loopback\n' > "$GNUPGHOME/gpg.conf"

if [[ -n "${GPG_PASSPHRASE_FILE:-}" ]]; then
  cp "$GPG_PASSPHRASE_FILE" "$work/passphrase"
elif [[ -n "${GPG_PASSPHRASE:-}" ]]; then
  printf '%s' "$GPG_PASSPHRASE" > "$work/passphrase"
else
  echo "Set GPG_PASSPHRASE or GPG_PASSPHRASE_FILE." >&2
  exit 1
fi
chmod 600 "$work/passphrase"

if [[ -n "${GPG_PRIVATE_KEY_FILE:-}" ]]; then
  gpg --batch --yes --pinentry-mode loopback --passphrase-file "$work/passphrase" --import "$GPG_PRIVATE_KEY_FILE"
elif [[ -n "${GPG_PRIVATE_KEY:-}" ]]; then
  printf '%s\n' "$GPG_PRIVATE_KEY" > "$work/private.asc"
  gpg --batch --yes --pinentry-mode loopback --passphrase-file "$work/passphrase" --import "$work/private.asc"
else
  echo "Set GPG_PRIVATE_KEY or GPG_PRIVATE_KEY_FILE." >&2
  echo "In GitHub, add the private key and passphrase as repository secrets before publishing." >&2
  exit 1
fi

fpr=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
if [[ -z "$fpr" ]]; then
  echo "Import produced no secret key." >&2
  exit 1
fi

pub_fpr=$(gpg --batch --with-colons --import-options show-only --import "$root/keys/RPM-GPG-KEY" | awk -F: '$1 == "fpr" { print $10; exit }')
printf '%s:6:\n' "$fpr" | gpg --batch --import-ownertrust
if [[ "$fpr" != "$pub_fpr" ]]; then
  echo "The secret key does not match keys/RPM-GPG-KEY." >&2
  echo "secret ${fpr}" >&2
  echo "public ${pub_fpr}" >&2
  exit 1
fi

keyid=$(printf '%s' "$fpr" | tr '[:upper:]' '[:lower:]')
keyid=${keyid: -16}

signature_state() {
  local rpm=$1
  local info
  info=$(rpm -qp --nosignature --qf '%{RSAHEADER:pgpsig}\n%{DSAHEADER:pgpsig}\n%{SIGPGP:pgpsig}\n' "$rpm")
  if printf '%s\n' "$info" | grep -qi "key id ${keyid}"; then
    printf 'ours\n'
  elif printf '%s\n' "$info" | grep -Eiq 'key id [0-9a-f]'; then
    printf 'foreign\n'
  else
    printf 'unsigned\n'
  fi
}

sign_rpm() {
  local rpm=$1
  rpmsign --addsign \
    --define "_gpg_name ${fpr}" \
    --define "_openpgp_sign_id ${fpr}" \
    --define "_gpg_path ${GNUPGHOME}" \
    --define "_gpg_digest_algo sha256" \
    --define "_gpg_sign_cmd_extra_args --pinentry-mode loopback --passphrase-file ${work}/passphrase" \
    "$rpm"
}

while IFS= read -r -d '' rpm; do
  parent=$(basename "$(dirname "$rpm")")
  pkgarch=$(rpm -qp --nosignature --qf '%{ARCH}' "$rpm")
  sourcepackage=$(rpm -qp --nosignature --qf '%{SOURCEPACKAGE}' "$rpm")
  if [[ "$parent" == "SRPMS" ]]; then
    if [[ "$sourcepackage" != "1" ]]; then
      echo "Only source packages belong in SRPMS: $rpm" >&2
      exit 1
    fi
  elif [[ "$parent" == "noarch" && "$pkgarch" != "noarch" ]]; then
    echo "Only noarch packages belong in a noarch directory: $rpm" >&2
    exit 1
  elif [[ "$parent" != "noarch" && "$pkgarch" != "$parent" && "$pkgarch" != "noarch" ]]; then
    echo "Package arch ${pkgarch} does not match ${parent}: $rpm" >&2
    exit 1
  fi

  state=$(signature_state "$rpm")
  case "$state" in
    ours)
      echo "Already signed: $rpm"
      ;;
    unsigned)
      echo "Signing: $rpm"
      sign_rpm "$rpm"
      state=$(signature_state "$rpm")
      if [[ "$state" != "ours" ]]; then
        echo "Signature was not written: $rpm" >&2
        rpm -qp --qf 'RSA:%{RSAHEADER:pgpsig}\nDSA:%{DSAHEADER:pgpsig}\nPGP:%{SIGPGP:pgpsig}\n' "$rpm" >&2 || true
        exit 1
      fi
      ;;
    foreign)
      echo "Refusing a package signed by a different key: $rpm" >&2
      exit 1
      ;;
  esac
done < <(find packages -type f -name '*.rpm' -print0)

rpm --import "$root/keys/RPM-GPG-KEY"
while IFS= read -r -d '' rpm; do
  rpm -K "$rpm"
done < <(find packages -type f -name '*.rpm' -print0)

umask 022
rm -rf site
mkdir -p site
cp "$root/keys/RPM-GPG-KEY" site/RPM-GPG-KEY
cp "$root/keys/FINGERPRINT" site/FINGERPRINT
printf '%s\n' "$fpr" > site/FINGERPRINT
touch site/.nojekyll

cat > site/mergin.repo << EOF
[mergin-linuxpackages]
name=Mergin Linux Packages for Fedora \$releasever (\$basearch)
baseurl=${base}/fedora/\$releasever/\$basearch
enabled=1
gpgcheck=1
pkg_gpgcheck=1
repo_gpgcheck=1
gpgkey=${base}/RPM-GPG-KEY
metadata_expire=2h
EOF

shopt -s nullglob
releases=(packages/fedora/*/)
for release_dir in "${releases[@]}"; do
  release=$(basename "$release_dir")
  arches=()
  arch_dirs=("${release_dir}"*/)
  for arch_dir in "${arch_dirs[@]}"; do
    arch=$(basename "$arch_dir")
    [[ "$arch" == "noarch" || "$arch" == "SRPMS" ]] && continue
    arches+=("$arch")
  done
  if [[ ${#arches[@]} -eq 0 && -d "${release_dir}/noarch" ]]; then
    arches=(x86_64 aarch64)
  fi

  for arch in "${arches[@]}"; do
    dest="site/fedora/${release}/${arch}"
    mkdir -p "$dest"
    if [[ -d "${release_dir}/${arch}" ]]; then
      find "${release_dir}/${arch}" -maxdepth 1 -type f -name '*.rpm' -exec cp -a {} "$dest/" \;
    fi
    if [[ -d "${release_dir}/noarch" ]]; then
      find "${release_dir}/noarch" -maxdepth 1 -type f -name '*.rpm' -exec cp -a {} "$dest/" \;
    fi
    createrepo_c --checksum sha256 --general-compress-type zstd "$dest"
    gpg --batch --yes --pinentry-mode loopback --passphrase-file "$work/passphrase" \
      --local-user "$fpr" --detach-sign --armor \
      --output "$dest/repodata/repomd.xml.asc" \
      "$dest/repodata/repomd.xml"
    gpg --verify "$dest/repodata/repomd.xml.asc" "$dest/repodata/repomd.xml"
  done
done

pretty_fpr=$(printf '%s' "$fpr" | sed 's/.\{4\}/& /g; s/ $//')
created=$(gpg --batch --with-colons --list-keys "$fpr" | awk -F: '$1 == "pub" { print $6; exit }')
expires=$(gpg --batch --with-colons --list-keys "$fpr" | awk -F: '$1 == "pub" { print $7; exit }')
created_day=$(date -u -d "@${created}" +%Y-%m-%d)
expires_day=$(date -u -d "@${expires}" +%Y-%m-%d)

html_escape() {
  local value=$1
  value=${value//&/\&amp;}
  value=${value//</\&lt;}
  value=${value//>/\&gt;}
  value=${value//\"/\&quot;}
  printf '%s' "$value"
}

{
  cat << EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mergin Linux Packages</title>
<style>
  body { font: 17px/1.5 sans-serif; max-width: 46rem; margin: 2.5rem auto; padding: 0 1.2rem; color: #1c1c1c; background: #fff; }
  code, pre { font-family: ui-monospace, SFMono-Regular, monospace; }
  pre { background: #f3f3f1; padding: 0.85rem 1rem; overflow: auto; }
  table { border-collapse: collapse; width: 100%; margin: 1rem 0 2rem; }
  th, td { text-align: left; padding: 0.35rem 0.6rem 0.35rem 0; border-bottom: 1px solid #e4e4e4; vertical-align: top; }
  h1 { font-size: 1.7rem; line-height: 1.2; }
</style>
</head>
<body>
<h1>Mergin Linux Packages</h1>
<p>Signed RPM repository for Fedora.</p>
<pre>sudo dnf config-manager addrepo --from-repofile=${base}/mergin.repo</pre>
<p>On the first add, dnf may ask for the key twice. Both prompts should show this fingerprint:</p>
<pre>${pretty_fpr}</pre>
<p>The key was created on ${created_day} and expires on ${expires_day}.</p>
EOF

  found=0
  while IFS= read -r -d '' rpm; do
    if [[ $found -eq 0 ]]; then
      echo "<h2>Packages</h2>"
      echo "<table><thead><tr><th>Package</th><th>Version</th><th>Architecture</th><th>Summary</th></tr></thead><tbody>"
      found=1
    fi
    IFS=$'\t' read -r pkg_name pkg_evr pkg_arch pkg_summary < <(rpm -qp --nosignature --qf '%{NAME}\t%{EVR}\t%{ARCH}\t%{SUMMARY}\n' "$rpm")
    rel_path=${rpm#site/}
    printf '<tr><td><a href="%s">%s</a></td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
      "$(html_escape "$rel_path")" \
      "$(html_escape "$pkg_name")" \
      "$(html_escape "$pkg_evr")" \
      "$(html_escape "$pkg_arch")" \
      "$(html_escape "$pkg_summary")"
  done < <(find site/fedora -type f -name '*.rpm' -print0 | sort -z)

  if [[ $found -eq 1 ]]; then
    echo "</tbody></table>"
  else
    echo "<p>No packages published yet.</p>"
  fi

  cat << 'EOF'
</body>
</html>
EOF
} > site/index.html

write_readme() {
  local rows="" rpm fedora name evr
  while IFS= read -r -d '' rpm; do
    fedora=$(basename "$(dirname "$(dirname "$rpm")")")
    IFS=$'\t' read -r name evr < <(rpm -qp --nosignature --qf '%{NAME}\t%{EVR}\n' "$rpm")
    rows+="${fedora}"$'\t'"${name}"$'\t'"${evr}"$'\n'
  done < <(find packages/fedora -type f -name '*.rpm' -print0)

  {
    echo "# Mergin Linux Packages"
    echo
    echo "## Public key"
    echo
    echo '```'
    cat "$root/keys/RPM-GPG-KEY"
    echo '```'
    echo
    echo "## Packages"
    echo
    echo "| Package | Version | Fedora |"
    echo "| --- | --- | --- |"
    if [[ -n "$rows" ]]; then
      printf '%s' "$rows" | sort -t $'\t' -k1,1n -k2,2 -k3,3 | uniq | while IFS=$'\t' read -r fedora name evr; do
        printf '| %s | %s | %s |\n' "$name" "$evr" "$fedora"
      done
    fi
  } > "$root/README.md"
}

write_readme

echo "Repository written to ${root}/site"
echo "baseurl ${base}"
