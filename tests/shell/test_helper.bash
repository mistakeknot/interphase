#!/usr/bin/env bash
# Shared test helper for beads-lifecycle bats tests

# Resolve directories relative to this file
HOOKS_DIR="$BATS_TEST_DIRNAME/../../hooks"
export CLAUDE_PLUGIN_ROOT="$BATS_TEST_DIRNAME/../.."

# Load bats-support and bats-assert from npm global modules
# Try common npm global paths (Linux, macOS Homebrew, and the active npm prefix)
NPM_GLOBAL=""
for candidate in /usr/lib/node_modules /usr/local/lib/node_modules \
                 /opt/homebrew/lib/node_modules "$(npm root -g 2>/dev/null)"; do
    if [[ -d "$candidate/bats-support" ]]; then
        NPM_GLOBAL="$candidate"
        break
    fi
done

if [[ -n "$NPM_GLOBAL" ]]; then
    load "$NPM_GLOBAL/bats-support/load"
    load "$NPM_GLOBAL/bats-assert/load"
fi

# Stub network commands to prevent real network calls in tests
stub_network() {
    curl() { return 1; }
    wget() { return 1; }
    export -f curl wget
}
