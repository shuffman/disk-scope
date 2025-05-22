# disk-scope Installation and Usage Guide

## Prerequisites

Before installing disk-scope, ensure you have the following prerequisites:

1. Perl 5.10 or higher
2. CPAN package manager
3. SQLite 3 or higher
4. Make utility (for easy installation)

## Installation

You can install disk-scope using the provided Makefile:

```bash
# Clone the repository
git clone https://github.com/yourusername/disk-scope.git
cd disk-scope

# Install the tool and its dependencies
make install
```

This will:
- Install all required Perl modules
- Create a `disk-scope` executable in your `~/bin` directory
- Set up necessary library directories

If you prefer to install manually, you can:

```bash
# Install required CPAN modules
cpan -i DBI DBD::SQLite Mojolicious JSON Time::localtime File::Find::Rule Term::ANSIColor

# Create lib directory and make script executable
mkdir -p lib
chmod +x disk-scope.pl

# Optionally copy to a location in your PATH
cp disk-scope.pl ~/bin/disk-scope
```

## Usage

disk-scope has four main modes of operation:

### 1. Analyze

This mode scans a directory and stores information about files that exceed a specified size.

```bash
disk-scope analyze --db disk-scope.db --path /path/to/analyze --min-size 100MB
```

Options:
- `--db`: Path to the SQLite database file (will be created if it doesn't exist)
- `--path`: Directory to analyze
- `--min-size`: Minimum file size to include in the analysis (e.g., 100MB, 1GB)

### 2. List

This mode lists all analysis runs stored in the database.

```bash
disk-scope list --db disk-scope.db
```

Options:
- `--db`: Path to the SQLite database file

### 3. Report

This mode generates a report of files from a previous analysis run, categorized by age.

```bash
disk-scope report --db disk-scope.db --id 1 --age 1w --age 1m --age 6m --min-size 100MB
```

Options:
- `--db`: Path to the SQLite database file
- `--id`: ID of the analysis run to report on
- `--age`: Age bucket for files (can be specified multiple times)
  - Format: Nw (weeks), Nm (months), Ny (years)
- `--user`: Optional filter to show only files owned by a specific user
- `--min-size`: Minimum file size to include in the report

### 4. Web Interface

This mode launches a web server that provides a graphical interface to the database.

```bash
disk-scope web --db disk-scope.db
```

Options:
- `--db`: Path to the SQLite database file

Once launched, you can access the web interface by opening a browser and navigating to:
```
http://localhost:3000
```

## Examples

```bash
# Analyze your home directory, storing files larger than 500MB
disk-scope analyze --db disk-scope.db --path /home/user --min-size 500MB

# List all analysis runs
disk-scope list --db disk-scope.db

# Generate a report of files older than 1 week, 1 month, and 6 months
disk-scope report --db disk-scope.db --id 1 --age 1w --age 1m --age 6m --min-size 100MB

# Filter report to show only files owned by a specific user
disk-scope report --db disk-scope.db --id 1 --age 1w --age 1m --user john --min-size 100MB

# Launch the web interface
disk-scope web --db disk-scope.db
```

## Troubleshooting

If you encounter any issues:

1. Ensure all required Perl modules are installed
2. Check that the database file is accessible
3. Verify that you have permissions to read the directories being analyzed
4. For the web interface, make sure port 3000 is not in use by another application

## Uninstallation

To remove disk-scope:

```bash
# Remove the executable
rm ~/bin/disk-scope

# Optionally remove the cloned repository and database files
rm -rf /path/to/disk-scope/repository
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. 