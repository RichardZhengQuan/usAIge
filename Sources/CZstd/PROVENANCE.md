# Zstandard decoder

This target vendors the official Zstandard **v1.5.7** decompression-only
amalgamation under its BSD-3-Clause license option. The upstream notices in the
generated source are retained without changes, and the BSD license is reproduced
in `LICENSE.txt`. The project does not use the GPL license option.

Source: https://github.com/facebook/zstd/tree/v1.5.7

Archive: https://github.com/facebook/zstd/archive/refs/tags/v1.5.7.tar.gz

Archive SHA-256:
`37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3`

Generation uses the official `build/single_file_libs/combine.py`:

```sh
python3 combine.py -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c
```

Generated size: 927,181 bytes. Generated SHA-256:
`5eb38abe0a7eea13674b312a006df72002d4192f0f0b4d09e6f03fb927a1f3d0`

The generated file is renamed `vendor/zstddeclib.inc` so Swift Package Manager
compiles it exactly once through `CZstd.c`. Only the bounded project wrapper is
exposed to Swift. No runtime installation, dynamic library, Python interpreter,
compression tool, credentials, or network access is required.

The wrapper accepts one dictionary-free frame, caps output at 1 MiB and the
declared window at 8 MiB, and rejects truncated data, concatenated frames,
skippable frames, trailing bytes, corruption, and exceeded limits.
