# Semantius Core CLI

A powerful command-line interface built with Deno for the Semantius Core project.

## Prerequisites

- [Deno](https://deno.land/) 1.37+ installed

## Installation

Clone the repository and navigate to the project directory:

```bash
git clone <repository-url>
cd semantius-core
```

## Usage

### Basic Commands

```bash
# Show help
deno run --allow-read --allow-write --allow-env cli.ts --help

# Show version
deno run --allow-read --allow-write --allow-env cli.ts --version

# Initialize a new project
deno run --allow-read --allow-write --allow-env cli.ts init

# Build the project
deno run --allow-read --allow-write --allow-env cli.ts build

# Run tests
deno run --allow-read --allow-write --allow-env cli.ts test

# Run linter
deno run --allow-read --allow-write --allow-env cli.ts lint

# Format code
deno run --allow-read --allow-write --allow-env cli.ts format
```

### Using Deno Tasks (Recommended)

The project includes predefined tasks in `deno.json`:

```bash
# Start the CLI
deno task start

# Initialize project
deno task init

# Build project
deno task build

# Run tests
deno task test

# Run linter
deno task lint

# Format code
deno task fmt

# Type check
deno task check
```

### Command Options

- `--verbose`: Enable verbose output for commands
- `--config <FILE>`: Specify a custom config file path
- `--output <DIR>`: Specify output directory for build command

### Examples

```bash
# Initialize with verbose output
deno task start init --verbose

# Build to custom directory
deno task start build --output ./dist

# Run tests with verbose output
deno task start test --verbose
```

## Project Structure

After running `deno task init`, your project will have:

```
semantius-core/
├── src/
│   └── main.ts          # Main application entry point
├── tests/
│   └── main_test.ts     # Test files
├── cli.ts               # CLI application
├── deno.json            # Deno configuration
└── README.md            # This file
```

## Development

### Adding New Commands

To add a new command to the CLI:

1. Add the command case to the switch statement in `cli.ts`
2. Implement the command function
3. Update the help text
4. Add tests for the new command

### Testing

Run tests with:

```bash
deno task test
```

### Linting and Formatting

Keep code clean with:

```bash
deno task lint  # Check for linting issues
deno task fmt   # Format code
```

## Permissions

The CLI requires the following Deno permissions:

- `--allow-read`: Read files and directories
- `--allow-write`: Write files and directories
- `--allow-env`: Access environment variables

These are necessary for file operations, project initialization, and running subcommands.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests and linting
5. Submit a pull request

## License

See [LICENSE](LICENSE) file for details.