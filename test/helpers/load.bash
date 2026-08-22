# Bootstrap for bats-support/bats-assert, plus common path helpers.
# `load test/helpers/load` (bats resolves relative to the test file, or via BATS_TEST_DIRNAME).

TEST_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Canonicalized once via `cd` (not left as a literal "../.." in a path string) — some sandboxed
# shells reject a literal ".." path component even when it resolves inside the allowed tree.
TEST_ROOT="$(cd "${TEST_HELPERS_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${TEST_ROOT}/.." && pwd)"

load "${TEST_HELPERS_DIR}/bats-support/load.bash"
load "${TEST_HELPERS_DIR}/bats-assert/load.bash"
load "${TEST_HELPERS_DIR}/fakes.bash"

export REPO_ROOT TEST_ROOT
