test:
	TEST_FILES=$$TEST_FILES nvim --headless -S "./tests/init.lua"

.PHONY: test
