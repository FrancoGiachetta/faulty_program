CAIRO_2_VERSION=2.6.4

bench: build needs-cairo2 runtime
	./scripts/bench-hyperfine.sh

bench-ci: check-llvm needs-cairo2 runtime
	cargo criterion --all-features

stress-test: check-llvm
	RUST_LOG=cairo_native_stress=DEBUG cargo run --bin cairo-native-stress 1000000 --output cairo-native-stress-logs.jsonl

stress-plot:
	python3 src/bin/cairo-native-stress/plotter.py cairo-native-stress-logs.jsonl

stress-clean:
	rm -rf .aot-cache

install: check-llvm
	RUSTFLAGS="-C target-cpu=native" cargo install --all-features --locked --path .

clean:
	cargo clean

deps:
ifeq ($(UNAME), Linux)
deps: build-cairo-2-compiler install-scarb
endif
ifeq ($(UNAME), Darwin)
deps: deps-macos
endif
	-rm -rf corelib
	-ln -s cairo2/corelib corelib

deps-macos: build-cairo-2-compiler-macos install-scarb-macos
	-brew install llvm@18 --quiet
	@echo "You can execute the env-macos.sh script to setup the needed env variables."

cairo-repo-2-dir = cairo2
cairo-repo-2-dir-macos = cairo2-macos

build-cairo-2-compiler-macos: | $(cairo-repo-2-dir-macos)

$(cairo-repo-2-dir-macos): cairo-${CAIRO_2_VERSION}-macos.tar
	$(MAKE) decompress-cairo SOURCE=$< TARGET=cairo2/

build-cairo-2-compiler: | $(cairo-repo-2-dir)

$(cairo-repo-2-dir): cairo-${CAIRO_2_VERSION}.tar
	$(MAKE) decompress-cairo SOURCE=$< TARGET=cairo2/

decompress-cairo:
	rm -rf $(TARGET) \
	&& tar -xzvf $(SOURCE) \
	&& mv cairo/ $(TARGET)

cairo-%-macos.tar:
	curl -L -o "$@" "https://github.com/starkware-libs/cairo/releases/download/v$*/release-aarch64-apple-darwin.tar"

cairo-%.tar:
	curl -L -o "$@" "https://github.com/starkware-libs/cairo/releases/download/v$*/release-x86_64-unknown-linux-musl.tar.gz"

SCARB_VERSION = 2.6.4

install-scarb:
	curl --proto '=https' --tlsv1.2 -sSf https://docs.swmansion.com/scarb/install.sh| sh -s -- --no-modify-path --version $(SCARB_VERSION)

install-scarb-macos:
	curl --proto '=https' --tlsv1.2 -sSf https://docs.swmansion.com/scarb/install.sh| sh -s -- --version $(SCARB_VERSION)

build-alexandria:
	cd tests/alexandria; scarb build

runtime:
	cargo b --release --all-features -p cairo-native-runtime && cp target/release/libcairo_native_runtime.a .

runtime-ci:
	cargo b --profile ci --all-features -p cairo-native-runtime && cp target/ci/libcairo_native_runtime.a .
