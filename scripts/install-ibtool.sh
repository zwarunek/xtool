#!/bin/bash
# Builds xtool-ibtool and links it into the installed Darwin SDK as the platforms' ibtool, so
# SwiftBuild can compile .xib files on Linux. Run from the xtool checkout:
#   scripts/install-ibtool.sh [path/to/darwin.artifactbundle]
set -euo pipefail
cd "$(dirname "$0")/.."
bundle=${1:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}
swift build -c release --product xtool-ibtool
ibtool="$(swift build -c release --show-bin-path)/xtool-ibtool"
for platform in iPhoneOS iPhoneSimulator; do
  bin="$bundle/Developer/Platforms/$platform.platform/Developer/usr/bin"
  mkdir -p "$bin"
  ln -sf "$ibtool" "$bin/ibtool"
  echo "linked $bin/ibtool -> $ibtool"
done
# SwiftBuild searches the Swift toolchain's usr/bin before the platforms, so an ibtool there wins.
toolchain_ibtool="$(dirname "$(readlink -f "$(command -v swift)")")/ibtool"
if [ -e "$toolchain_ibtool" ] || [ -L "$toolchain_ibtool" ]; then
  echo "warning: $toolchain_ibtool exists and is used instead; remove it or link it to $ibtool" >&2
fi
