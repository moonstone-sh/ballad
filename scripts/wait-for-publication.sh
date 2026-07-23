#!/usr/bin/env sh
set -eu

descriptor_path=${1:?usage: wait-for-publication.sh <package.toml>}
registry_url=${MOONSTONE_REGISTRY_URL:-https://registry.moonstone.sh/registry/v0}
registry_url=${registry_url%/}
attempts=${MOONSTONE_PUBLICATION_ATTEMPTS:-90}
interval=${MOONSTONE_PUBLICATION_INTERVAL:-4}

package_name=$(awk '
  /^\[package\]$/ { in_package = 1; next }
  in_package && /^\[/ { exit }
  in_package && /^name = / { sub(/^name = "/, ""); sub(/"$/, ""); print; exit }
' "$descriptor_path")
package_version=$(awk '
  /^\[package\]$/ { in_package = 1; next }
  in_package && /^\[/ { exit }
  in_package && /^version = / { sub(/^version = "/, ""); sub(/"$/, ""); print; exit }
' "$descriptor_path")

if [ -z "$package_name" ] || [ -z "$package_version" ]; then
  printf '%s\n' "error: $descriptor_path must contain [package] name and version" >&2
  exit 2
fi

index_has_package() {
  awk -v expected_name="$package_name" -v expected_version="$package_version" '
    function matches() { return name == expected_name && version == expected_version }
    /^\[\[package\]\]$/ {
      if (matches()) exit 0
      name = ""
      version = ""
      next
    }
    /^name = / { value = $0; sub(/^name = "/, "", value); sub(/"$/, "", value); name = value }
    /^version = / { value = $0; sub(/^version = "/, "", value); sub(/"$/, "", value); version = value }
    END { exit matches() ? 0 : 1 }
  '
}

descriptor_matches_package() {
  awk -v expected_name="$package_name" -v expected_version="$package_version" '
    /^\[package\]$/ { in_package = 1; next }
    in_package && /^\[/ { exit }
    in_package && name == "" && /^name = / { value = $0; sub(/^name = "/, "", value); sub(/"$/, "", value); name = value }
    in_package && version == "" && /^version = / { value = $0; sub(/^version = "/, "", value); sub(/"$/, "", value); version = value }
    END { exit name == expected_name && version == expected_version ? 0 : 1 }
  '
}

attempt=1
while [ "$attempt" -le "$attempts" ]; do
  index=$(mktemp)
  remote_descriptor=$(mktemp)
  trap 'rm -f "$index" "$remote_descriptor"' EXIT INT TERM

  if curl --fail --silent --show-error "$registry_url/index.toml" -o "$index" 2>/dev/null \
    && curl --fail --silent --show-error "$registry_url/packages/$package_name/$package_version/package.toml" -o "$remote_descriptor" 2>/dev/null \
    && index_has_package < "$index" \
    && descriptor_matches_package < "$remote_descriptor"; then
    printf '%s\n' "Published $package_name@$package_version is resolvable from $registry_url"
    rm -f "$index" "$remote_descriptor"
    trap - EXIT INT TERM
    exit 0
  fi

  rm -f "$index" "$remote_descriptor"
  trap - EXIT INT TERM
  if [ "$attempt" -eq "$attempts" ]; then
    break
  fi
  printf '%s\n' "Waiting for $package_name@$package_version to appear in the public registry ($attempt/$attempts)..." >&2
  sleep "$interval"
  attempt=$((attempt + 1))
done

printf '%s\n' "error: $package_name@$package_version uploaded but did not become resolvable from $registry_url" >&2
exit 1
