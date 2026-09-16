#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="$project_dir/build"
app_dir="$output_dir/Fx.app"
module_cache_dir="$project_dir/.build/ModuleCache"

cd "$project_dir"
mkdir -p "$module_cache_dir"

# Keep compiler modules in the project. This avoids stale or unwritable global
# caches and lets the installed Swift compiler rebuild SDK modules for macOS 26.
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$module_cache_dir}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$module_cache_dir}"

if [[ ! -d "$project_dir/Runtime/node_modules" ]]; then
    npm ci --prefix "$project_dir/Runtime"
fi
npm run build --prefix "$project_dir/Runtime"
swift build -c release

if [[ -d "$app_dir" ]]; then
    rm -rf "$app_dir"
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/.build/release/Fx" "$app_dir/Contents/MacOS/Fx"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/soda-engineering-system.md" "$app_dir/Contents/Resources/soda-engineering-system.md"
cp "$project_dir/Resources/justoneapi-contexts.json" "$app_dir/Contents/Resources/justoneapi-contexts.json"
mkdir -p "$app_dir/Contents/Resources/FxRuntime"
cp "$project_dir/Runtime/package.json" "$app_dir/Contents/Resources/FxRuntime/package.json"
cp "$project_dir/Runtime/package-lock.json" "$app_dir/Contents/Resources/FxRuntime/package-lock.json"
cp -R "$project_dir/Runtime/dist" "$app_dir/Contents/Resources/FxRuntime/dist"
cp -R "$project_dir/Runtime/node_modules" "$app_dir/Contents/Resources/FxRuntime/node_modules"
# The app runs compiled JavaScript. Keep compiler/type tooling in the source
# checkout, and remove only development dependencies from the copied bundle.
npm prune --omit=dev --ignore-scripts --offline --no-audit --no-fund \
    --prefix "$app_dir/Contents/Resources/FxRuntime"

# TCC permissions are tied to the app's code requirement. Re-signing every
# development build ad-hoc changes that identity and makes Accessibility look
# untrusted again. Prefer a stable local identity; callers can override it with
# FX_SIGNING_IDENTITY, and machines without a certificate still fall back
# to ad-hoc signing.
signing_identity="${FX_SIGNING_IDENTITY:-}"
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
