#!/bin/bash
# On the Mac: run every corpus kernel with generated inputs through Apple's and our metallib and compare outputs.
cd ~/scratch-metal/corpus
xcrun swiftc -O -o mtltest ../suite/tests/harness/mtltest.swift -framework Metal || exit 1
H=./mtltest
: > auto.tsv
for f in ours/*.metallib; do
  id=$(basename $f .metallib); r=out-ref2/$(basename $f)
  [ -f "$r" ] || continue
  perl -e 'alarm shift; exec @ARGV' 300 $H auto $r $f 2>/dev/null | sed "s|^|$id\t|" >> auto.tsv
done
echo "kernels: $(wc -l < auto.tsv)"; cut -f2 auto.tsv | sort | uniq -c
