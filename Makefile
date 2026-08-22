.PHONY: lint test test-live

lint:
	shellcheck -S warning $$(find . -name '*.sh' -not -path './.git/*' -not -path './.intake/*' -not -path './scripts/*' -not -path './test/bats-core/*' -not -path './test/helpers/bats-support/*' -not -path './test/helpers/bats-assert/*')
	@for f in $$(find . -name '*.sh' -not -path './.git/*' -not -path './.intake/*' -not -path './scripts/*' -not -path './test/bats-core/*' -not -path './test/helpers/bats-support/*' -not -path './test/helpers/bats-assert/*'); do bash -n "$$f" || exit 1; done

test:
	test/bats-core/bin/bats test/unit test/integration

test-live:
	RUN_LIVE_TESTS=1 test/bats-core/bin/bats test/live
