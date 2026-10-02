# Vendored CoreMark

EEMBC CoreMark, <https://github.com/eembc/coremark>, tag `v1.01` (the only upstream tag), commit
`cfa9ab377835911f23d9b0831c7be302ed1f58de`, taken unchanged from the GitHub tarball
(sha256 `99c5a6d63af85a281b4e4d6ccb522c446653c435dfec9455ad73ef9e71f28bde`). Only the sources the
`linux64` port needs are kept (`core_*.c`, `coremark.h`, `linux64/core_portme.[ch]`, license, upstream
README). The iPhone benchmark vendors the same tag at the same path, so both phones run identical code.

Built by `randroid device bench` for arm64 Android with the NDK at `-O2`; see `../bench.py`.
