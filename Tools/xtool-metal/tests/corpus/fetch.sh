#!/bin/bash
# Fetch the public shader corpus used for compile and load checks (not vendored here).
set -e
cd "$(dirname "$0")"
for r in twostraws/Inferno@a40c7a0 MetalPetal/MetalPetal@f9b7889 krispuckett/SwiftUIShaders@6b644a8 Treata11/iShader@849c12e \
         donaldwuid/apple_metal_sample_code@0bc50e5 raphaelsalaja/metallurgy@15bda76 schwa/MetalSprockets@7eb6be9; do
  repo=${r%@*}; rev=${r#*@}; dir=$(basename $repo)
  [ -d "$dir" ] || git clone -q https://github.com/$repo "$dir"
  git -C "$dir" checkout -q "$rev" 2>/dev/null || true
done
