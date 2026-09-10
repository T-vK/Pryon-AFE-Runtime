.DEFAULT_GOAL := help
BUILD ?= build
DIST ?= dist

.PHONY: help configure build test check local-ci build-android package clean firmware emulator-test emulator-pipeline-test setup-emulator live-mic-emulator test-real
help:
	@echo 'make configure       Configure the host build'
	@echo 'make build           Build binaries and mocks'
	@echo 'make test            Run CTest and language checks'
	@echo 'make local-ci        Run GitHub Actions CI jobs locally with act/Docker'
	@echo 'make build-android   Cross-build Android ARMv7/Bionic targets'
	@echo 'make package         Create individual release files and checksums'
	@echo 'make firmware        Download and unpack the default firmware'
	@echo 'make emulator-test   Run Pryon in the Echo emulator'
	@echo 'make emulator-pipeline-test Run real AFE/Pryon in the Echo emulator'
	@echo 'make setup-emulator  Download firmware and build the pinned emulator kernel'
	@echo 'make live-mic-emulator Stream the host microphone through the Echo emulator'
	@echo 'make test-real       Run real-library file tests; add REAL_TEST_ARGS="--mic --beep" for microphone tests'

configure:
	cmake -S . -B $(BUILD) -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo

build: configure
	cmake --build $(BUILD)

test: build
	@command -v python3 >/dev/null 2>&1 || { echo 'make test: missing dependency: python3' >&2; echo '  Linux: sudo apt install python3' >&2; echo '  macOS: brew install python' >&2; exit 1; }
	@command -v go >/dev/null 2>&1 || { echo 'make test: missing dependency: Go' >&2; echo '  Linux: sudo apt install golang-go' >&2; echo '  macOS: brew install go' >&2; exit 1; }
	ctest --test-dir $(BUILD) --output-on-failure
	python3 -m py_compile examples/python/pryon_afe.py
	(cd examples/go && go test ./...)

check: test
	@command -v shellcheck >/dev/null 2>&1 || { echo 'make check: missing dependency: shellcheck' >&2; echo '  Linux: sudo apt install shellcheck' >&2; echo '  macOS: brew install shellcheck' >&2; exit 1; }
	shellcheck -S warning examples/bash/*.sh tools/*.sh tools/internal/*.sh tests/*.sh

local-ci:
	tools/test-actions-local.sh

build-android:
	@test -n "$(ANDROID_NDK_HOME)" || { echo 'Android NDK 26.3.11579264 is required.' >&2; echo '  Linux: sdkmanager "ndk;26.3.11579264"' >&2; echo '  macOS: install Android Studio or command-line tools, then sdkmanager "ndk;26.3.11579264"' >&2; echo '  Set ANDROID_NDK_HOME to the installed NDK directory.' >&2; exit 1; }
	rm -rf build-android
	cmake -S . -B build-android -G Ninja -DBUILD_TESTING=OFF -DCMAKE_TOOLCHAIN_FILE=$(ANDROID_NDK_HOME)/build/cmake/android.toolchain.cmake -DANDROID_ABI=armeabi-v7a -DANDROID_PLATFORM=android-22 -DCMAKE_BUILD_TYPE=Release
	cmake --build build-android

package: build
	@test -n "$(RELEASE_VERSION)" || { echo 'set RELEASE_VERSION=x.y.z'; exit 1; }
	tools/package.sh $(BUILD) $(DIST) $(RELEASE_VERSION)

firmware:
	tools/download-firmware.sh

emulator-test: build-android
	@test -n "$(FIRMWARE_ROOT)" -a -n "$(EMULATOR_KERNEL)" || { echo 'set FIRMWARE_ROOT and EMULATOR_KERNEL'; exit 1; }
	tools/run-emulator.sh --root $(FIRMWARE_ROOT) --kernel $(EMULATOR_KERNEL) --binary build-android/pryon --mode pryon

emulator-pipeline-test: build-android
	@test -n "$(FIRMWARE_ROOT)" -a -n "$(EMULATOR_KERNEL)" -a -n "$(EMULATOR_INPUT)" || { echo 'set FIRMWARE_ROOT, EMULATOR_KERNEL, and EMULATOR_INPUT'; exit 1; }
	tools/run-emulator.sh --root $(FIRMWARE_ROOT) --kernel $(EMULATOR_KERNEL) --mode pipeline --afe-binary build-android/afe --pryon-binary build-android/pryon --input $(EMULATOR_INPUT) --require-event

setup-emulator:
	tools/setup-emulator.sh

live-mic-emulator:
	tools/run-live-mic-emulator.sh

test-real: build-android
	tools/test-real.sh $(REAL_TEST_ARGS)

clean:
	rm -rf build build-android dist
