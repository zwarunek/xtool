#!/bin/bash
# Build xtool-metal (the `metal`/`metallib` replacement) into ./out.
#   LLVM=/path/to/clang+llvm-15 ./build.sh
# Without LLVM set, downloads the LLVM 15.0.6 release (the last LLVM that writes typed-pointer bitcode,
# which Apple's AIR reader requires).
set -euo pipefail
cd "$(dirname "$0")"
LLVM=${LLVM:-}
if [ -z "$LLVM" ]; then
  LLVM=$PWD/.llvm15
  if [ ! -x "$LLVM/bin/clang" ]; then
    url=https://github.com/llvm/llvm-project/releases/download/llvmorg-15.0.6/clang+llvm-15.0.6-x86_64-linux-gnu-ubuntu-18.04.tar.xz
    mkdir -p "$LLVM"
    curl -fsSL "$url" | tar xJ -C "$LLVM" --strip-components=1
  fi
fi
mkdir -p out/bin out/include
CLANG_LIBS="-lclangCodeGen -lclangFrontend -lclangSerialization -lclangDriver -lclangParse -lclangSema -lclangAnalysis -lclangEdit -lclangAST -lclangASTMatchers -lclangLex -lclangBasic -lclangSupport"
${CXX:-g++} -std=c++17 -O1 -fno-rtti -fno-exceptions -D_GNU_SOURCE -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS \
  -D__STDC_LIMIT_MACROS -I"$LLVM/include" src/xtmetal.cpp -o out/bin/xtmetal -L"$LLVM/lib" \
  -Wl,--start-group $CLANG_LIBS $("$LLVM/bin/llvm-config" --libs all) -Wl,--end-group \
  $("$LLVM/bin/llvm-config" --system-libs) -lz -ltinfo
python3 stdlib/gen_stdlib.py out/include
cp driver/metal driver/msl_rewrite.py out/bin/
ln -sf metal out/bin/metallib
ln -sf "$LLVM/bin/clang" out/bin/clang
echo "built $(pwd)/out"
