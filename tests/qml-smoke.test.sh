#!/usr/bin/env bash
# Compiles and instantiates the plugin's QML outside the running shell, so a
# syntax or binding error fails here instead of showing up as a blank bar slot.
#
# Model.js is covered separately: node --test tests/model.test.js
set -euo pipefail

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
log_file=$(mktemp /tmp/devnull-qml-smoke.XXXXXX.log)
test_dir=$(mktemp -d /tmp/devnull-qml-smoke.XXXXXX)

cleanup() {
  rm -f -- "$log_file"
  rm -f -- "$test_dir/shell.qml" "$test_dir/DevNull" "$test_dir/Commons" "$test_dir/Ui"
  rmdir -- "$test_dir"
}
trap cleanup EXIT

ln -s "$plugin_dir/tests/QmlSmokeHarness.qml" "$test_dir/shell.qml"
ln -s "$plugin_dir" "$test_dir/DevNull"
ln -s /usr/share/omarchy/shell/Commons "$test_dir/Commons"
ln -s /usr/share/omarchy/shell/Ui "$test_dir/Ui"

timeout 25 quickshell -p "$test_dir/shell.qml" 2>&1 | tee "$log_file" || true

if grep -q "DEVNULL_SMOKE_OK" "$log_file"; then
  exit 0
fi

echo "--- qml smoke test failed ---" >&2
grep -E "DEVNULL_SMOKE_FAIL|error|Error|warning: .*(qml|Quick)" "$log_file" >&2 || true
exit 1