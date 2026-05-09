#!/bin/bash
cd "$(dirname "$0")"
source ./script/setup.sh

./script/check-uncommitted-files.sh

./build-debug.sh -Xswiftc -warnings-as-errors
./swift-test.sh

./.debug/mur -h > /dev/null
./.debug/mur --help > /dev/null
./.debug/mur -v | grep -q "0.0.0-SNAPSHOT SNAPSHOT"
./.debug/mur --version | grep -q "0.0.0-SNAPSHOT SNAPSHOT"

./lint.sh --check-uncommitted-files
./generate.sh
./script/check-uncommitted-files.sh

echo
echo "✅ All tests have passed successfully"
