# DPLL Tool Versions

This directory contains two versions of the DPLL (Digital Phase-Locked Loop) utility:

## 1. dpll (YNL-based)

**Source:** `dpll.c`
**Dependencies:**
- Kernel YNL library (`tools/net/ynl` from kernel source)
- Generated DPLL netlink code
- Requires `KERNEL_SRC` to be set and YNL library to be built

**Features:**
- Uses YNL (YAML Netlink) library for netlink communication
- Type-safe generated code from YAML specifications
- Automatic request/response structure handling
- Better integration with kernel development workflow

**Build:**
```bash
./configure --kernel-source=/path/to/kernel/source
make dpll
```

## 2. dpll-mnl (libmnl-based)

**Source:** `dpll-mnl.c`
**Dependencies:**
- libmnl (Minimalistic Netlink library)
- Standard iproute2 libraries

**Features:**
- Uses libmnl for netlink communication
- Manual netlink message construction and parsing
- Smaller dependency footprint
- Standard iproute2 tool architecture (similar to devlink)
- More portable - doesn't require kernel source tree

**Build:**
```bash
make dpll-mnl
```

## Comparison

| Feature | dpll (YNL) | dpll-mnl (libmnl) |
|---------|------------|------------------|
| Dependencies | YNL library, kernel source | libmnl only |
| Code generation | Auto from YAML | Manual |
| Binary size | 200KB | 164KB |
| Complexity | Lower (generated) | Higher (manual) |
| Type safety | Strong (generated) | Manual validation |
| Portability | Requires kernel source | Standalone |
| Parent-device/pin support | Full | **Full** |
| Nested attributes | Auto-generated | Manual (mnl_attr_nest) |

## Functional Differences

Both versions support **identical functionality**:
- Device management (show, set, id-get)
- Pin management (show, set, id-get)
- Monitor mode for notifications
- Full support for nested attributes (parent-device, parent-pin, reference-sync)
- All pin configuration options (frequency, direction, prio, state, phase-adjust, esync-frequency)

**There are no functional limitations in dpll-mnl** - it provides complete feature parity with the YNL version.

## Usage

Both tools have identical command-line interface:

```bash
# Show all devices
dpll device show
dpll-mnl device show

# Set device parameters
dpll device set id 0 phase-offset-monitor true
dpll-mnl device set id 0 phase-offset-monitor true

# Show all pins
dpll pin show
dpll-mnl pin show

# Monitor notifications
dpll monitor
dpll-mnl monitor
```

## Recommendation

- **For kernel development:** Use `dpll` (YNL-based) for better integration with kernel netlink changes
- **For distribution packages:** Use `dpll-mnl` (libmnl-based) for simpler dependencies
- **For testing:** Either version works for basic functionality
