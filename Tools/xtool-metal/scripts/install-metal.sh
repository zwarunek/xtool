#!/bin/bash
# Link xtool-metal's `metal` and `metallib` into a Swift toolchain's usr/bin, where SwiftBuild looks for them.
#   scripts/install-metal.sh <toolchain usr/bin>
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
dest=${1:?toolchain usr/bin directory}
for t in metal metallib; do ln -sf "$here/out/bin/metal" "$dest/$t"; done
echo "linked metal, metallib into $dest"
