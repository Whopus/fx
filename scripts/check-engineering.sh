#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox --cache-path "$project_dir/.build/cache"
binary_dir="$(swift build --disable-sandbox --cache-path "$project_dir/.build/cache" --show-bin-path)"
objects=("${(@f)$(<"$binary_dir/Fx.product/Objects.LinkFileList")}")
objects=("${(@)objects:#*/FxApp.swift.o}")
# Link the real debug implementation without its GUI entry point. This is an
# offline regression harness, not a substitute for the complete XCTest suite.
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx26.2" \
    -I "$binary_dir/Modules" \
    Tests/FxTests/EngineeringChecks.swift scripts/engineering-checks-main.swift \
    "${objects[@]}" -o "$binary_dir/FxEngineeringChecks"
FX_RUNTIME_PATH="$project_dir/Tests/Fixtures/runtime-smoke.mjs" "$binary_dir/FxEngineeringChecks"
