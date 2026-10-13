#!/bin/bash
# On the Mac: for every corpus file both compilers built, compare function lists and build kernel pipelines.
cd ~/scratch-metal/corpus
H=../suite/tests/harness/mtltest
same=0; diff=0; fail=0; n=0
for f in ours/*.metallib; do
  id=$(basename $f); r=out-ref2/$id
  [ -f "$r" ] || continue
  n=$((n+1))
  a=$($H info $r 2>&1 | sed 's/ constants=.*//'); b=$($H info $f 2>&1 | sed 's/ constants=.*//')
  if [ "$a" != "$b" ]; then diff=$((diff+1)); echo "LIST DIFF $id"; diff <(echo "$a") <(echo "$b") | head -4; continue; fi
  c=$($H check $f 2>&1 | tail -3)
  case "$c" in *", 0 failures"*) same=$((same+1));; *) fail=$((fail+1)); echo "CHECK FAIL $id: $c" | head -3;; esac
done
echo "load-check: $same ok, $diff function-list differences, $fail pipeline failures, of $n"
