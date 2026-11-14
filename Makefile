ZIG ?= zig
OUT ?= dist

.PHONY: all build amd64 arm64 test check checksums clean

all: build

build: amd64 arm64

amd64:
	$(ZIG) build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix $(OUT)/amd64
	cp $(OUT)/amd64/bin/clearme $(OUT)/clearme-amd64

arm64:
	$(ZIG) build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe --prefix $(OUT)/arm64
	cp $(OUT)/arm64/bin/clearme $(OUT)/clearme-arm64

checksums: build
	cd $(OUT) && sha256sum clearme-amd64 clearme-arm64 > sha256sums.txt

test:
	$(ZIG) build test

check:
	$(ZIG) build fmt
	sh -n install.sh

clean:
	rm -rf $(OUT) zig-out .zig-cache
