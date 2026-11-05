#!/bin/sh
# With only the Command Line Tools, the compiler is not always told where the
# Swift Testing macro plugin is, and recompiling the tests then fails.
set -eu

cd "$(dirname "$0")"
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$plugins" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins"
fi
exec swift test
