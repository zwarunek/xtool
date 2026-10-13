#!/bin/bash
# usage: run_probes.sh <dir of .metal> <outdir> [extra metal flags]
src=$1; out=$2; shift 2
mkdir -p $out
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
export SDK out
compile() {
  f=$1; b=$(basename $f .metal)
  for mode in fast safe; do
    if xcrun metal -c -target air64-apple-ios15.0-simulator -isysroot $SDK -fmetal-math-mode=$mode -fmetal-math-fp32-functions=$([ $mode = fast ] && echo fast || echo precise) $EXTRA -o $out/$b.$mode.air $f 2> $out/$b.$mode.err; then
      xcrun metal-opt -S $out/$b.$mode.air -o $out/$b.$mode.ll && rm $out/$b.$mode.air $out/$b.$mode.err
    fi
  done
}
export -f compile
export EXTRA="$*"
ls $src/*.metal | xargs -P 8 -I{} bash -c 'compile {}'
echo done $(ls $out/*.ll | wc -l) ll, $(ls $out/*.err 2>/dev/null | wc -l) errors
