#!/bin/zsh
# Produces Xcode actool reference outputs for comparison tests. Run on a Mac with Xcode.
# Usage: make-references.sh <output dir> <catalog.xcassets>...
# Writes <output dir>/NN/{out/Assets.car, partial.plist, deps, stdout.plist, NoExt.swift, NoExt.h, catalog.txt}.
set -u
R=$1; shift
mkdir -p $R
i=0
for c in "$@"; do
  i=$((i+1)); n=$(printf "%02d" $i)
  d=$R/$n; rm -rf $d; mkdir -p $d/out
  echo "$c" > $d/catalog.txt
  icon=$(ls -d "$c"/*.appiconset(N) 2>/dev/null | head -1)
  extra=()
  [ -n "$icon" ] && extra+=(--app-icon "$(basename "$icon" .appiconset)")
  xcrun actool --output-format xml1 --notices --warnings --export-dependency-info $d/deps --output-partial-info-plist $d/partial.plist \
    --compress-pngs --enable-on-demand-resources NO --development-region en --target-device iphone --target-device ipad \
    --minimum-deployment-target 26.0 --platform iphoneos $extra --compile $d/out "$c" > $d/stdout.plist 2> $d/stderr.txt
  xcrun actool --output-format xml1 --platform iphoneos --minimum-deployment-target 26.0 --compile $d/symout "$c" \
    --bundle-identifier com.example.test --generate-swift-asset-symbol-extensions NO \
    --generate-swift-asset-symbols $d/NoExt.swift --generate-objc-asset-symbols $d/NoExt.h --generate-asset-symbol-index $d/NoExt-Index.plist > /dev/null 2>&1
  rm -rf $d/symout
  echo "$n $(ls $d/out | tr '\n' ' ') $c"
done
