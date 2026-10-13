#!/bin/bash
# Build xtool-metal (the `metal`/`metallib` replacement) into ./out.
#   LLVM=/path/to/clang+llvm-15 ./build.sh
# Without LLVM set, downloads the LLVM 15.0.6 release (the last LLVM that writes typed-pointer bitcode,
# which Apple's AIR reader requires).
set -euo pipefail
cd "$(dirname "$0")"
LLVM=${LLVM:-}
if [ -z "$LLVM" ]; then
  # clang/LLVM 15.0.6 built from source with clang-patches/apply.py (MSL semantics); about an hour on 8 cores.
  LLVM=$PWD/.llvm15p
  if [ ! -f "$LLVM/lib/libclangSema.a" ]; then
    src=$PWD/.llvm-src; build=$PWD/.llvm-build
    if [ ! -d "$src" ]; then
      mkdir -p "$src"
      curl -fsSL https://github.com/llvm/llvm-project/releases/download/llvmorg-15.0.6/llvm-project-15.0.6.src.tar.xz | tar xJ -C "$src" --strip-components=1
    fi
    python3 clang-patches/apply.py "$src"
    cmake -G Ninja -S "$src/llvm" -B "$build" -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_PROJECTS=clang \
      -DLLVM_TARGETS_TO_BUILD=X86 -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
      -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF -DCLANG_INCLUDE_TESTS=OFF -DLLVM_ENABLE_ZSTD=OFF \
      -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF -DCLANG_ENABLE_ARCMT=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
      -DCMAKE_INSTALL_PREFIX="$LLVM"
    ninja -C "$build" install
  fi
fi
mkdir -p out/bin out/include
PATCHED=""
if nm -C "$LLVM/lib/libclangSema.a" 2>/dev/null | grep -c "clang::XtMSL" >/dev/null; then PATCHED=-DXT_PATCHED_CLANG; fi
CLANG_LIBS="-lclangCodeGen -lclangFrontend -lclangSerialization -lclangDriver -lclangParse -lclangSema -lclangAnalysis -lclangEdit -lclangAST -lclangASTMatchers -lclangLex -lclangBasic -lclangSupport"
${CXX:-g++} $PATCHED -std=c++17 -O1 -fno-rtti -fno-exceptions -D_GNU_SOURCE -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS \
  -D__STDC_LIMIT_MACROS -I"$LLVM/include" src/xtmetal.cpp -o out/bin/xtmetal -L"$LLVM/lib" \
  -Wl,--start-group $CLANG_LIBS $("$LLVM/bin/llvm-config" --libs all) -Wl,--end-group \
  $("$LLVM/bin/llvm-config" --system-libs) -lz -ltinfo
python3 stdlib/gen_stdlib.py out/include
cp driver/metal driver/msl_rewrite.py out/bin/
ln -sf metal out/bin/metallib
ln -sf "$LLVM/bin/clang" out/bin/clang
echo "built $(pwd)/out"
