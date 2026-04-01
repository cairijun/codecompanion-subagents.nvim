NVIM := nvim

.PHONY: all test test_file deps clean

all: test

# Run all tests
test: deps
	@echo "Running tests..."
	$(NVIM) --headless --noplugin -u ./tests/nvim_init.lua -c "lua MiniTest.run()" -c "qa!"

# Run a specific test file
test_file: deps
ifndef FILE
	$(error FILE is required. Usage: make test_file FILE=tests/test_foo_bar.lua)
endif
	@echo "Testing file: $(FILE)"
	$(NVIM) --headless --noplugin -u ./tests/nvim_init.lua -c "lua MiniTest.run_file('$(FILE)')" -c "qa!"

# Install dependencies
deps: deps/mini.nvim deps/plenary.nvim deps/nvim-treesitter deps/codecompanion.nvim

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $@

deps/plenary.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/nvim-lua/plenary.nvim $@

deps/nvim-treesitter:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/nvim-treesitter/nvim-treesitter $@

deps/codecompanion.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/olimorris/codecompanion.nvim $@

format:
	stylua tests/ lua/

# Clean dependencies
clean:
	rm -rf deps/
	rm -rf tests/stubs/
