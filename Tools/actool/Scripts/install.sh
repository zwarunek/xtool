#!/bin/bash
# Builds actool and installs it where Swift Build looks for it: the iPhoneOS and iPhoneSimulator platform
# tool directories of the Darwin SDK that `xtool sdk install` set up. Swift Build searches the Swift
# toolchain's usr/bin first, so an actool there (for example an experiment stub) must be removed.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=${XTOOL_DARWIN_SDK:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}
swift build -c release --build-system native --static-swift-stdlib
for platform in iPhoneOS iPhoneSimulator; do
    dir="$SDK/Developer/Platforms/$platform.platform/Developer/usr/bin"
    mkdir -p "$dir"
    install -m 755 .build/release/actool "$dir/actool"
    echo "installed $dir/actool"
done
toolchain_bin=$(dirname "$(readlink -f "$(command -v swift)")")
if [ -e "$toolchain_bin/actool" ] || [ -L "$toolchain_bin/actool" ]; then
    echo "warning: $toolchain_bin/actool exists and takes precedence; remove it to use this actool" >&2
fi
