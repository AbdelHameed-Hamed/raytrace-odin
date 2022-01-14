@echo off

rem clang++ -O3 -march=native -DTRACY_ENABLE -c odin-tracy/tracy/TracyClient.cpp -o odin-tracy/tracy.lib
ispc tile_trace.ispc --target=avx2 -O0 -g -o tile_trace.o
odin run . -show-timings -microarch:native -debug -lld -define:TRACY_ENABLE=true