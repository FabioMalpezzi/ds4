# Wired-memory reproduction for issue #638

Isolated benchmark showing that Metal wires entire mmap-backed views on first
GPU use, while explicit `pread`-filled slot buffers stay bounded.

Build and run (macOS, Apple Silicon):

    clang -O2 -fobjc-arc -framework Metal -framework Foundation -o wired_repro wired_repro.m
    dd if=/dev/urandom of=data.bin bs=8388608 count=1024     # 8 GiB test file
    ./wired_repro pread data.bin 304                          # slot arm: ~2 GiB touched
    ./wired_repro mmap  data.bin 304                          # mmap arm: same 2 GiB touched

Each run prints system wired memory before/after fill/after GPU plus a
checksum (CPU and GPU must agree, and both arms must agree with each other).
Measured on M4 Max (macOS 26): pread arm wired growth ≤ 0.8 GiB; mmap arm
+8-10 GiB for the same bytes read. Interleave runs (pread/mmap/pread/mmap)
to control for machine state.
