default:
    @just --list

build:
    zig build

test:
    zig build test

run:
    zig build run

fmt:
    zig fmt src/

install: build
    codesign -s - zig-out/bin/tuikit
    cp zig-out/bin/tuikit /usr/local/bin/tuikit

clean:
    rm -rf zig-out .zig-cache
