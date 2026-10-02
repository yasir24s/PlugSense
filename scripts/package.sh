#!/bin/bash
# Builds dist/PlugSense-<version>.pkg, which installs PlugSense.app into /Applications and the
# plugsense command into /usr/local/bin. Set SIGN_IDENTITY to a "Developer ID Installer: …" identity
# to sign it.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${VERSION:-0.1.1}"
VERSION="$version" ./scripts/bundle.sh

root=$(mktemp -d)
components=$(mktemp)
trap 'rm -rf "$root" "$components"' EXIT
mkdir -p "$root/Applications" "$root/usr/local/bin"
cp -R dist/PlugSense.app "$root/Applications/"
cp dist/plugsense "$root/usr/local/bin/"

# Install the app where it says, never "relocated" to wherever an older copy was moved.
pkgbuild --analyze --root "$root" "$components" >/dev/null
/usr/libexec/PlistBuddy -c "Delete :0:BundleIsRelocatable" "$components" 2>/dev/null || true   # newer pkgbuilds omit it
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$components"

pkg="dist/PlugSense-$version.pkg"
sign=()
if [[ -n "${SIGN_IDENTITY:-}" ]]; then sign=(--sign "$SIGN_IDENTITY" --timestamp); fi
pkgbuild --root "$root" --component-plist "$components" --identifier com.plugsense.pkg --version "$version" \
         --install-location / ${sign[@]+"${sign[@]}"} "$pkg"
shasum -a 256 "$pkg"
