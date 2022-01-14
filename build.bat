@echo off

ispc tile_trace.ispc --target=avx2 -O0 -g -o tile_trace.o
odin run . -show-timings -microarch:native -debug -strict-style -lld