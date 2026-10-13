#!/bin/bash
# usage: compile_all.sh <metal command> <outdir> [target]
# Compiles every .metal file under the corpus dir (cwd) and links it; writes <outdir>/results.tsv.
METAL=$1; OUT=$2; TARGET=${3:-air64-apple-ios17.0-simulator}
mkdir -p $OUT
: > $OUT/results.tsv
find . -name '*.metal' -not -path "./$OUT/*" | sort | while read f; do
  id=$(echo "${f#./}" | tr '/ ' '__')
  d=$(dirname "$f")
  t0=$(date +%s.%N)
  if $METAL -c -target $TARGET -fmetal-math-mode=fast $EXTRA -I "$d" -o "$OUT/$id.air" "$f" > "$OUT/$id.log" 2>&1; then
    if $METAL -target $TARGET -o "$OUT/$id.metallib" "$OUT/$id.air" >> "$OUT/$id.log" 2>&1; then
      printf '%s\tok\t%s\n' "$id" "$(python3 -c "import sys;print('%.3f'%(float(sys.argv[2])-float(sys.argv[1])))" $t0 $(date +%s.%N))" >> $OUT/results.tsv
    else
      printf '%s\tlinkfail\t%s\n' "$id" "$(grep -m1 -i error $OUT/$id.log | cut -c1-200)" >> $OUT/results.tsv
    fi
  else
    printf '%s\tfail\t%s\n' "$id" "$(grep -m1 'error' $OUT/$id.log | cut -c1-220)" >> $OUT/results.tsv
  fi
done
echo "$(grep -c $'\tok\t' $OUT/results.tsv) ok of $(wc -l < $OUT/results.tsv)"
