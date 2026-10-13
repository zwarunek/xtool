# xtool-metal

A Linux replacement for Apple's `metal` and `metallib` tools: it compiles Metal Shading Language (MSL)
to AIR and links AIR into `.metallib` files that `MTLDevice.makeLibrary(data:)` loads.

SwiftBuild compiles `.metal` resources with `metal -c -target air64-apple-<os><version>[-simulator] ...`
and links them with `metal -target ... -o default.metallib *.air`. Those tools ship only with Xcode.
`scripts/install-metal.sh <toolchain>/usr/bin` puts these replacements where SwiftBuild looks for them.

## How it works

1. **Preprocess** with clang 15 in C++ for OpenCL mode against our own Metal standard library headers
   (`stdlib/gen_stdlib.py` generates them).
2. **Rewrite** MSL syntax that clang does not parse (`driver/msl_rewrite.py`): `[[buffer(0)]]` style
   attributes become `[[clang::annotate("air:buffer", 0)]]`, `vertex`/`fragment`/`kernel` become
   annotations, `device`/`constant`/`threadgroup` become OpenCL address spaces (which use the same numbers
   as AIR), and `float4(a, b)` vector construction becomes a call to a constexpr helper.
3. **Compile** (`src/xtmetal.cpp`, linked against the clang/LLVM 15 libraries): the AST gives the entry
   points, their argument attributes and struct layouts; clang generates the function bodies; xtmetal
   wraps each entry point in an AIR function with Apple's argument conventions (stage_in structs
   flattened into scalar/vector arguments, packed struct returns), emits the `!air.vertex`,
   `!air.fragment`, `!air.kernel`, `!air.visible` metadata (argument descriptions, struct type info,
   stitching info for `[[stitchable]]` functions), lowers conversions to `air.convert.*`, constant
   samplers to `!air.sampler_states`, threadgroup variables to `addrspace(3)` globals, and writes LLVM 15
   bitcode with the `air64_vNN-apple-...` triple. LLVM 15 is the last LLVM that writes typed pointers,
   which Apple's AIR reader requires.
4. **Link** (`xtmetal link`): one bitcode module per function, written into the MTLB container
   (function list with NAME/TYPE/HASH/OFFT/VERS/MDSZ tags, metadata sections, UUID).

The standard library calls AIR intrinsics by name (`air.fast_sin.f32`, `air.sample_texture_2d.v4f32`,
...). The names and signatures were found by compiling probe shaders (`tools/gen_math.py`,
`tools/run_probes.sh`) with Apple's compiler and reading the AIR it produced.

## Building

```sh
./build.sh                      # downloads the LLVM 15.0.6 release unless LLVM=/path is set
scripts/install-metal.sh /path/to/swift-toolchain/usr/bin
```

## Testing

`tests/shaders` holds test shaders (render, compute, textures, samplers, threadgroup memory, atomics,
`[[stitchable]]` SwiftUI effects), and `tests/cases` describes how to run them. The check needs a Mac:

```sh
tests/run_linux.sh out/bin/metal                    # on Linux: build tests/out/ours/*.metallib
tests/run_mac.sh air64-apple-ios15.0-simulator      # on a Mac: build Apple's versions, run both, compare
```

`run_mac.sh` compiles each shader with Apple's `metal`, renders or dispatches every case with both
libraries through `tests/harness/mtltest.swift` (stitchable functions go through SwiftUI's
`ShaderLibrary` and `ImageRenderer`), and compares the output bytes.

## Status

Public corpus (Inferno, MetalPetal, Apple sample code mirror, iShader, metallurgy, SwiftUIShaders,
MetalSprockets; `tests/corpus/fetch.sh`): 242 of 244 files compile and link. The other two include
headers that are not in the corpus, and Apple's compiler fails on them too. For every file both compilers
build, the function list matches Apple's and every compute pipeline builds on the GPU (or fails the same way
Apple's does). Compile + link takes about 0.2 s per file with the precompiled standard library.

`tests/corpus/auto_compare.sh` runs `mtltest auto` on the Mac. It dispatches every compute kernel and
renders every vertex+fragment pair, using generated inputs taken from pipeline reflection (typed buffer
contents, textures, samplers, vertex descriptors, required function constants). It first compares the
binding layout, then compares the output bytes against Apple's build of the same file. Cases where Apple's
own two runs differ, or Apple's pipeline fails with the generated inputs, are skipped.

Covered: vertex/fragment/kernel/visible/stitchable, mesh and object functions, intersection functions
and ray tracing (intersectors, intersection queries, acceleration structures, function tables),
imageblocks (implicit/explicit, MSAA color rates, sample masks) and pixel-format types, post-tessellation
vertex functions, and indirect command buffers. Not yet: debug info.
