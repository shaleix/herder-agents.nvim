# 每个目标一个独立 headless nvim（plenary test_directory 收尾即 qa，单进程
# 跑不完多个目标）；TEST_FILES 支持空格/逗号分隔多个目标，缺省全量 tests/specs。
test:
	@targets=$${TEST_FILES:-tests/specs}; \
	for t in $$targets; do \
	  echo "== $$t =="; \
	  TEST_FILES="$$t" nvim --headless -S "./tests/init.lua" || exit 1; \
	done

.PHONY: test
