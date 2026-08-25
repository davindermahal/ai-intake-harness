.PHONY: lint test test-live

lint:
	shellcheck -S warning $$(find . -name '*.sh' -not -path './.git/*' -not -path './.intake/*' -not -path './scripts/*' -not -path './test/bats-core/*' -not -path './test/helpers/bats-support/*' -not -path './test/helpers/bats-assert/*')
	@for f in $$(find . -name '*.sh' -not -path './.git/*' -not -path './.intake/*' -not -path './scripts/*' -not -path './test/bats-core/*' -not -path './test/helpers/bats-support/*' -not -path './test/helpers/bats-assert/*'); do bash -n "$$f" || exit 1; done

test:
	test/bats-core/bin/bats test/unit test/integration

test-live:
	RUN_LIVE_TESTS=1 test/bats-core/bin/bats test/live

# Self-hosted-only targets (worktree-go, intake-status, etc. — this repo dogfooding its own
# harness) live in Makefile.local, gitignored since they're host-specific the same way
# scripts/intake-cron.sh and .ai/intake.config are. Silently a no-op include when absent, so
# vendoring this Makefile into a consumer's ai-intake-harness/ subtree stays harmless.
-include Makefile.local
