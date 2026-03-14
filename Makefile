# Makefile
.PHONY: test lint check clean install

# Run all tests
test:
	@echo "Running tests..."
	@bats tests/

# Run ShellCheck
lint:
	@echo "Running ShellCheck..."
	@shellcheck cc-cron.sh

# Run all checks
check: lint test

# Clean test artifacts
clean:
	@rm -rf test-results/ *.tap

# Install to local bin
install:
	@chmod +x cc-cron.sh
	@ln -sf "$$(pwd)/cc-cron.sh" ~/.local/bin/cc-cron

# Install bash completion
install-completion:
	@echo 'eval "$$(cc-cron completion)"' >> ~/.bashrc
	@echo "Bash completion installed. Restart your shell."