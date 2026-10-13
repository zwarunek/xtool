#!/bin/bash
# Compile every test shader with xtmetal into out/ours/<shader>.metallib.
# usage: run_linux.sh <metal driver> [target]
set -e
METAL=${1:?metal driver}; TARGET=${2:-air64-apple-ios15.0-simulator}
cd "$(dirname "$0")"
mkdir -p out/ours
fail=0
for s in shaders/*.metal; do
  b=$(basename $s .metal)
  if "$METAL" -c -target $TARGET -fmetal-math-mode=fast -o out/ours/$b.air $s 2> out/ours/$b.log &&
     "$METAL" -target $TARGET -o out/ours/$b.metallib out/ours/$b.air 2>> out/ours/$b.log; then
    echo "ok   $b"
  else
    echo "FAIL $b: $(head -3 out/ours/$b.log)"; fail=1
  fi
done
exit $fail
