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
    cp zig-out/bin/tuikit /usr/local/bin/tuikit
    codesign -s - /usr/local/bin/tuikit

clean:
    rm -rf zig-out .zig-cache
