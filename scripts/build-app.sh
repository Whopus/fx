#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="$project_dir/build"
app_dir="$output_dir/Curatez.app"

cd "$project_dir"
if [[ ! -d "$project_dir/Runtime/node_modules" ]]; then
    npm install --prefix "$project_dir/Runtime"
fi
npm run build --prefix "$project_dir/Runtime"
swift build -c release

if [[ -d "$app_dir" ]]; then
    rm -rf "$app_dir"
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/.build/release/Curatez" "$app_dir/Contents/MacOS/Curatez"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/soda-engineering-system.md" "$app_dir/Contents/Resources/soda-engineering-system.md"
cp "$project_dir/Resources/justoneapi-contexts.json" "$app_dir/Contents/Resources/justoneapi-contexts.json"
mkdir -p "$app_dir/Contents/Resources/CuratezRuntime"
cp "$project_dir/Runtime/package.json" "$app_dir/Contents/Resources/CuratezRuntime/package.json"
cp "$project_dir/Runtime/package-lock.json" "$app_dir/Contents/Resources/CuratezRuntime/package-lock.json"
cp -R "$project_dir/Runtime/dist" "$app_dir/Contents/Resources/CuratezRuntime/dist"
cp -R "$project_dir/Runtime/node_modules" "$app_dir/Contents/Resources/CuratezRuntime/node_modules"

# TCC permissions are tied to the app's code requirement. Re-signing every
# development build ad-hoc changes that identity and makes Accessibility look
# untrusted again. Prefer a stable local identity; callers can override it with
# CURATEZ_SIGNING_IDENTITY, and machines without a certificate still fall back
# to ad-hoc signing.
signing_identity="${CURATEZ_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    identity_output="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    signing_identity="$(
        print -r -- "$identity_output" \
            | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
            | head -n 1
    )"
    if [[ -z "$signing_identity" ]]; then
        signing_identity="$(
            print -r -- "$identity_output" \
                | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
                | head -n 1
        )"
    fi
fi
signing_identity="${signing_identity:--}"

codesign --force --deep --sign "$signing_identity" "$app_dir"
echo "Signed with: $signing_identity"

echo "$app_dir"
