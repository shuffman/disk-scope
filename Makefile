.PHONY: install test clean

PERL_PATH := $(shell which perl)
LIB_DIR := $(shell pwd)/lib
BIN_DIR := $(HOME)/bin

install:
	@echo "Installing required CPAN modules..."
	cpan -i DBI DBD::SQLite Mojolicious JSON Time::localtime File::Find::Rule Term::ANSIColor
	@echo "Creating executable script..."
	mkdir -p $(BIN_DIR)
	cp -f disk-scope.pl $(BIN_DIR)/disk-scope
	chmod +x $(BIN_DIR)/disk-scope
	@echo "Creating lib directory..."
	mkdir -p $(LIB_DIR)
	@echo "Installation complete!"
	@echo "You can now use disk-scope from anywhere."
	@echo "Usage examples:"
	@echo "  disk-scope analyze --db disk-scope.db --path /home --min-size 100MB"
	@echo "  disk-scope list --db disk-scope.db"
	@echo "  disk-scope report --db disk-scope.db --id 1 --age 1w --age 1m --age 6m --min-size 100MB"
	@echo "  disk-scope web --db disk-scope.db"

test:
	@echo "Running tests..."
	perl -c disk-scope.pl
	perl -c lib/WebApp.pm
	@echo "All tests passed!"

clean:
	@echo "Cleaning up..."
	rm -f *.db
	@echo "Clean up complete!" 