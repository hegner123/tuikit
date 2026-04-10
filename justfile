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
    cp zig-out/bin/tui-test-ghost /usr/local/bin/tui-test-ghost
    codesign -s - /usr/local/bin/tui-test-ghost

clean:
    rm -rf zig-out .zig-cache
