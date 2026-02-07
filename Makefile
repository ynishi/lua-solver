.PHONY: test fmt fmt-check

test:
	cd .. && lua lua_solver/test.lua

fmt:
	stylua .

fmt-check:
	stylua --check .
