#!/bin/bash
# On a Mac: compile every test shader with Apple's metal (reference), run each case against the
# reference and against out/ours/<shader>.metallib, and compare the outputs.
# usage: run_mac.sh [target] [case...]
TARGET=${1:-air64-apple-ios15.0-simulator}; shift
cd "$(dirname "$0")"
mkdir -p out/ref out/run
[ -x harness/mtltest ] && [ harness/mtltest -nt harness/mtltest.swift ] || swiftc -O -o harness/mtltest harness/mtltest.swift
for s in shaders/*.metal; do
  b=$(basename $s .metal)
  xcrun metal -c -target $TARGET -fmetal-math-mode=fast -o out/ref/$b.air $s 2> out/ref/$b.log && xcrun metal -target $TARGET -o out/ref/$b.metallib out/ref/$b.air 2>> out/ref/$b.log || echo "REF COMPILE FAIL $b"
done
pass=0; total=0
for c in ${@:-cases/*.json}; do
  c=${c#cases/}; c=${c%.json}; total=$((total+1))
  shader=$(python3 -c "import json;print(json.load(open('cases/$c.json'))['shader'])")
  fmt=$(python3 -c "import json;d=json.load(open('cases/$c.json'));print(d.get('compare', 'B' if d['kind']=='visible' else 'f'))")
  if ! harness/mtltest run out/ref/$shader.metallib cases/$c.json out/run/$c.ref > /dev/null 2> out/run/$c.ref.err; then echo "REF FAIL $c: $(head -c 200 out/run/$c.ref.err)"; continue; fi
  if ! harness/mtltest run out/ours/$shader.metallib cases/$c.json out/run/$c.ours > /dev/null 2> out/run/$c.ours.err; then echo "FAIL $c: $(head -c 300 out/run/$c.ours.err)"; continue; fi
  r=$(python3 harness/cmp.py out/run/$c.ref out/run/$c.ours $fmt)
  case "$r" in *identical=True*) pass=$((pass+1)); echo "same $c";; *) echo "DIFF $c: $r";; esac
done
echo "$pass/$total identical"
