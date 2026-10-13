Reference outputs produced by Xcode 26.5's `xcstringstool compile` on macOS (see run-ref.sh in the
ZWB-296 artifacts). Each fixture directory holds the input catalog, the files Xcode wrote (`expected/`),
its exit code (`expected.rc`) and its error lines (`expected-errors.txt`). Variants: `-force` adds
`--force-build-all-strings`, `-languages` adds `-l de -l fr -l en`, `-stringsdictOnly` adds
`--format stringsdictOnly`.

`expected-symbols.swift` is the output of `xcstringstool generate-symbols --language swift` for the same
catalog; `Symbols/` is a catalog that exercises symbol naming and argument types, with Xcode's errors in
`expected-symbol-errors.txt`.
