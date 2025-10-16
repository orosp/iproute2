# DPLL Tool for iproute2

This tool provides command-line interface for the Linux kernel DPLL (Digital Phase-Locked Loop) subsystem using YNL (YAML Netlink) library.

## Building

### Prerequisites

1. Linux kernel source with DPLL support (typically 6.x+)
2. YNL library built from kernel sources

### Configuration

From the iproute2 root directory:

```bash
./configure --include_dir=/path/to/kernel/source/include
make
```

The configure script will automatically detect the YNL library location based on the kernel include path. If YNL is not found, the dpll tool will be skipped during build.

## Usage

### Device Commands

Show all DPLL devices:
```bash
dpll device show
```

Show specific device:
```bash
dpll device show id 0
```

### JSON Output

All commands support JSON output:
```bash
dpll -j device show
dpll -j -p device show  # Pretty-printed JSON
```

## Testing

The tool can be tested even without DPLL hardware by checking help and version:

```bash
dpll -V
dpll help
dpll device help
```

For actual DPLL operations, you need:
- Kernel with DPLL subsystem enabled
- Hardware with DPLL support

## License

GPL-2.0-or-later
