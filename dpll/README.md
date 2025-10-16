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

Get device ID by attributes:
```bash
dpll device id-get module-name ice clock-id 0
dpll device id-get module-name ice type eec
```

Set device parameters:
```bash
dpll device set id 0 phase-offset-monitor true
dpll device set id 0 phase-offset-avg-factor 10
```

### Pin Commands

Show all pins:
```bash
dpll pin show
```

Show pins for specific device:
```bash
dpll pin show device 0
```

Show specific pin:
```bash
dpll pin show id 0
```

Get pin ID by attributes:
```bash
dpll pin id-get board-label "SMA1"
dpll pin id-get module-name ice clock-id 0 type ext
```

Set pin parameters:
```bash
dpll pin set id 0 frequency 10000000
dpll pin set id 0 prio 10 state connected
dpll pin set id 0 direction input
dpll pin set id 0 phase-adjust 100
dpll pin set id 0 esync-frequency 1000000
```

Set pin with parent devices:
```bash
dpll pin set id 0 parent-device 0 direction input prio 10 state connected
dpll pin set id 0 parent-device 0 direction input prio 10 parent-device 1 direction output prio 5
```

Set pin with parent pin:
```bash
dpll pin set id 0 parent-pin 1 state connected
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
dpll pin help
```

For actual DPLL operations, you need:
- Kernel with DPLL subsystem enabled
- Hardware with DPLL support

## License

GPL-2.0-or-later
