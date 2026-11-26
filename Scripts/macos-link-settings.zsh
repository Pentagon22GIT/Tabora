# Forward the selected SDK to the Clang link driver. Each target retains
# its own minimum OS (including the test runner's XCTest minimum).
readonly MINIMUM_MACOS_VERSION="13.0"
readonly MACOS_SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
readonly -a MACOS_LINK_FLAGS=(-Xswiftc -Xclang-linker -Xswiftc -isysroot
  -Xswiftc -Xclang-linker -Xswiftc "$MACOS_SDK_PATH")
