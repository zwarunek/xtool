# Interface Builder files on Linux

Compile `.xib` files in Swift packages without Xcode.

## Overview

SwiftBuild compiles each `.xib` resource by running `ibtool`, which only exists in Xcode. On Linux, xtool
provides `xtool-ibtool`, which turns iOS `.xib` files (Interface Builder document version 3) into the
NIBArchive `.nib` files that `UINib` loads.

`xtool sdk install` links `xtool-ibtool` into the Darwin SDK when it is built next to `xtool`. For an SDK
that is already installed, run `scripts/install-ibtool.sh` from the xtool checkout. SwiftBuild looks in the
Swift toolchain's `usr/bin` before the SDK's platforms, so remove any other `ibtool` there.

`xtool-ibtool` writes the same objects and keys as Xcode 26.5's ibtool for the classes it supports: views,
labels, buttons, text fields, switches, sliders, steppers, image views, table views and cells, search bars,
tap and pinch gesture recognizers, Auto Layout constraints (including safe area and margin constraints and
size class variations), outlets, outlet collections, actions and user-defined runtime attributes. It reports
anything else as a warning and leaves it out. Storyboards are not supported.

To check a nib against one Xcode built, run `xtool-ibtool --compare reference.nib candidate.nib`;
`xtool-ibtool --dump file.nib` prints a nib's object graph.
