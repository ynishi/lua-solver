.PHONY: test fmt fmt-check

test:
	LUA_PATH="$(shell cd .. && pwd)/?.lua;$(shell cd .. && pwd)/?/init.lua;;" lua test.lua

fmt:
	stylua .

fmt-check:
	stylua --check .
