@echo off

rem clang++ -O3 -march=native -DTRACY_ENABLE -c odin-tracy/tracy/TracyClient.cpp -o odin-tracy/tracy.lib
ispc src/tile_trace.ispc --target=avx2 -O0 -g -o tile_trace.o
odin run src/ -show-timings -microarch:native -opt:0 -debug -lld -strict-style-init-only