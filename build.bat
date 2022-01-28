@echo off

rem clang++ -O3 -march=native -DTRACY_ENABLE -c odin-tracy/tracy/TracyClient.cpp -o odin-tracy/tracy.lib
rem ispc tile_trace.ispc --target=avx2 -O0 -g -o tile_trace.o
odin run . -show-timings -microarch:native -opt:0 -debug -lld -strict-style-init-only -define:TRACY_ENABLE=true