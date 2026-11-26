#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
output="${1:-$source_dir/build/Repository Sidebar.app}"
if [[ $# -gt 1 || "$output" != *.app ]]; then
    printf 'Usage: %s [output.app]\n' "$0" >&2
    exit 2
fi

mkdir -p "$(dirname "$output")"
output_dir="$(cd "$(dirname "$output")" && pwd)"
output="$output_dir/$(basename "$output")"

if [[ -e "$output" || -L "$output" ]]; then
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$output/Contents/Info.plist" 2>/dev/null || true)"
    if [[ -L "$output" || "$identifier" != local.repository-sidebar ]]; then
        printf 'An unrelated item already exists at %s\n' "$output" >&2
        exit 1
    fi
fi

staging_dir="$(mktemp -d "$output_dir/.repository-sidebar.XXXXXX")"
previous_app="$staging_dir/Previous.app"
cleanup() {
    if [[ -d "$previous_app" && ! -e "$output" ]]; then
        mv "$previous_app" "$output" || return
    fi
    rm -rf "$staging_dir"
}
trap cleanup EXIT

app="$staging_dir/Repository Sidebar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
cp "$source_dir/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
    xcrun swiftc -sdk "$sdk" -target "$arch-apple-macosx14.0" \
        -swift-version 5 -parse-as-library -O \
        "$source_dir/GitRepository.swift" \
        "$source_dir/GitHubDesktopImport.swift" \
        "$source_dir/RepositoryCatalog.swift" \
        "$source_dir/RepositorySidebarApp.swift" \
        -o "$staging_dir/RepositorySidebar-$arch"
done
xcrun lipo -create "$staging_dir/RepositorySidebar-arm64" \
    "$staging_dir/RepositorySidebar-x86_64" \
    -output "$app/Contents/MacOS/RepositorySidebar"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

if [[ -e "$output" ]]; then
    mv "$output" "$previous_app"
fi
mv "$app" "$output"
printf '%s\n' "$output"
