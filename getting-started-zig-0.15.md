# Getting Started with Zig 0.15

A comprehensive guide to installing and working with Zig 0.15 on Ubuntu, including syntax changes, new I/O system, and documentation resources for LLM-powered agents.

---

## Table of Contents

1. [Installation on Ubuntu](#installation-on-ubuntu)
2. [Verifying the Installation](#verifying-the-installation)
3. [Major Changes in Zig 0.15](#major-changes-in-zig-015)
4. [The New Reader/Writer I/O System](#the-new-readerwriter-io-system)
5. [Notable Stdlib Changes](#notable-stdlib-changes)
6. [Documentation Resources for Agents](#documentation-resources-for-agents)
7. [Browsing Zig Source Code](#browsing-zig-source-code)
8. [Getting Help](#getting-help)

---

## Installation on Ubuntu

### Method 1: Automated Installation (Recommended)

This method downloads the latest Zig release automatically and installs it system-wide.

```bash
#!/bin/bash
# Fetch the latest Zig version
ZIG_VERSION=$(curl -s "https://api.github.com/repos/ziglang/zig/releases/latest" | grep -Po '"tag_name": "\K[0-9.]+')

# Download the Linux x86_64 binary
wget -qO zig.tar.xz https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz

# Create installation directory
sudo mkdir -p /opt/zig

# Extract to installation directory
sudo tar xf zig.tar.xz --strip-components=1 -C /opt/zig

# Create symlink for system-wide access
sudo ln -sf /opt/zig/zig /usr/local/bin/zig

# Clean up
rm -f zig.tar.xz

# Verify installation
zig version
```

### Method 2: Manual Download

If you prefer more control over the installation:

```bash
# Visit the official downloads page
# https://ziglang.org/download/

# Download your preferred version (e.g., 0.15.0)
wget https://ziglang.org/download/0.15.0/zig-linux-x86_64-0.15.0.tar.xz

# Extract
tar xf zig-linux-x86_64-0.15.0.tar.xz

# Move to /opt or ~/tools
sudo mv zig-linux-x86_64-0.15.0 /opt/zig

# Add to PATH
export PATH=$PATH:/opt/zig
# Permanently: add to ~/.bashrc or ~/.zshrc
echo 'export PATH=$PATH:/opt/zig' >> ~/.bashrc
source ~/.bashrc
```

### Method 3: Using Package Manager

Some distributions include Zig in their repositories (though versions may lag):

```bash
# Ubuntu/Debian
sudo apt install zig

# Fedora
sudo dnf install zig

# Arch Linux
sudo pacman -S zig
```

---

## Verifying the Installation

```bash
# Check Zig version
zig version

# Display help
zig --help

# Create a test program
cat > hello.zig << 'EOF'
const std = @import("std");

pub fn main() void {
    std.debug.print("Hello, Zig 0.15!\n", .{});
}
EOF

# Compile and run
zig build-exe hello.zig
./hello

# Or run directly
zig run hello.zig
```

---

## Major Changes in Zig 0.15

### 1. Removal of `usingnamespace`

**Impact**: Breaking change affecting namespace imports and mixins.

**Why**: The keyword added distance between expected and actual declaration locations, making code navigation difficult for humans and tooling.

**Migration**:

```zig
// Before (0.14)
pub usingnamespace CounterMixin(Foo);

// After (0.15) - Use zero-bit fields with @fieldParentPtr
counter: CounterMixin(Foo) = .{},

// Usage changes from:
foo.incrementCounter();  // Before
// To:
foo.counter.increment();  // After
```

### 2. Async/Await Removal from Language

**Impact**: `async` and `await` keywords removed; functionality moved to stdlib.

**Status**: Async I/O will be implemented via the new `std.Io.Reader` and `std.Io.Writer` interfaces (still in development).

### 3. Non-Exhaustive Enum Switch Improvements

```zig
// You can now mix explicit tags with underscore prong
switch (enum_val) {
    .special_case_1 => foo(),
    .special_case_2 => bar(),
    _, .special_case_3 => baz(),  // Both patterns work
}

// And have both else and _
switch (value) {
    .A => {},
    .C => {},
    else => {},  // Named tags
    _ => {},     // Unnamed tags
}
```

### 4. Safer Integer-to-Float Coercions

```zig
// This now compiles to an error (previously silent precision loss)
const f: f32 = 16777217;  // Error: integer not precisely representable

// Solution: use float literal instead
const f: f32 = 16777217.0;  // Ok: explicit float with rounding
```

### 5. Asm Syntax Changes

```zig
// Before (0.14)
asm volatile ("syscall"
    : [ret] "={rax}" (-> usize),
    : [number] "{rax}" (number),
      [arg1] "{rdi}" (arg1),
    : "rcx", "r11"
);

// After (0.15) - Clobbers use named struct syntax
asm volatile ("syscall"
    : [ret] "={rax}" (-> usize),
    : [number] "{rax}" (number),
      [arg1] "{rdi}" (arg1),
    : .{ .rcx = true, .r11 = true }
);
```

Run `zig fmt` to auto-upgrade your code.

### 6. Debug Build Performance

**5x faster debug compilation** with x86_64 self-hosted backend now default.

```bash
# Use LLVM backend if needed (some targets require it)
zig build -fllvm

# Or in build.zig:
exe.root_module.use_llvm = true;
```

---

## The New Reader/Writer I/O System

The most significant change in 0.15 is the complete overhaul of the I/O system, nicknamed **"Writergate"**.

### Key Principles

- **Non-generic interfaces**: `std.Io.Reader` and `std.Io.Writer` are concrete types, not generic
- **Buffer in interface, not implementation**: Hot paths run without virtual calls
- **Explicit buffering**: You control the buffer size and memory
- **Always flush**: Remember to call `.flush()` when done writing

### Basic Usage Pattern

```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Reading from stdin
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const reader: *std.Io.Reader = &stdin_reader.interface;

    // Writing to stdout
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout: *std.Io.Writer = &stdout_writer.interface;

    try stdout.print("Enter text: ", .{});
    try stdout.flush();

    if (try reader.takeDelimiterExclusive('\n')) |line| {
        try stdout.print("You entered: {s}\n", .{line});
    } else |err| switch (err) {
        error.EndOfStream => try stdout.print("End of stream\n", .{}),
        error.StreamTooLong => try stdout.print("Line too long\n", .{}),
        error.ReadFailed => try stdout.print("Read failed\n", .{}),
    }

    try stdout.flush();
}
```

### File Operations

```zig
// Reading a file
var file = try std.fs.cwd().openFile("data.txt", .{});
defer file.close();

var file_buffer: [4096]u8 = undefined;
var file_reader = file.reader(&file_buffer);

while (try file_reader.interface.readUntilDelimiterOrEof(delimiter, &line_buffer)) |line| {
    // Process line
}

// Writing a file
var file = try std.fs.cwd().createFile("output.txt", .{});
defer file.close();

var write_buffer: [4096]u8 = undefined;
var file_writer = file.writer(&write_buffer);
const writer: *std.Io.Writer = &file_writer.interface;

try writer.print("Hello, file!\n", .{});
try writer.flush();
```

### Available Reader Methods

```zig
// Reading single values
byte: u8 = try reader.readByte();
u32_value: u32 = try reader.readInt(u32, .big);  // big-endian

// Reading buffers
n = try reader.read(buffer);  // Returns bytes read
try reader.readNoEof(buffer);  // Error if EOF

// Reading until delimiter
line = try reader.takeDelimiterExclusive('\n');  // Exclusive
try reader.skipUntilDelimiter('\n');  // Skip without storing

// Reading all remaining
all = try reader.readAllAlloc(allocator, max_size);
try reader.readAllArrayList(&list);

// Peeking
byte = try reader.peekByte();
n = try reader.peek(buffer);
```

### Available Writer Methods

```zig
// Writing single values
try writer.writeByte(b);
try writer.writeInt(u32_value, .big);  // big-endian

// Writing buffers
try writer.writeAll(buffer);
try writer.print("Format: {s}\n", .{string});

// Context-specific
try writer.writeByteNTimes('=', 10);
try writer.writeFileAll(src_file);  // sendFile equivalent

// Flushing
try writer.flush();

// Special writers
const discard_count = try std.Io.Writer.Discarding.writeAll(writer, data);
const allocated_data = try std.Io.Writer.Allocating.writeAll(allocator, data);
```

### Format Specifiers

```zig
// Format specifiers have changed significantly
try writer.print("{s}", .{"string"});       // String
try writer.print("{d}", .{42});             // Decimal integer
try writer.print("{x}", .{255});            // Hex integer
try writer.print("{b64}", .{data});         // Base64 encoding
try writer.print("{}", .{value});           // Generic format

// Tag names (NEW in 0.15)
try writer.print("{t}", .{enum_value});     // Tag name
try writer.print("{t}", .{error_value});    // Error name

// Custom types with format methods (0.15 changes)
// Format methods now have simpler signature:
pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{}", .{this.field});
}
```

### HTTP Client/Server with New I/O

```zig
// Server setup
var recv_buffer: [4000]u8 = undefined;
var send_buffer: [4000]u8 = undefined;
var conn_reader = connection.stream.reader(&recv_buffer);
var conn_writer = connection.stream.writer(&send_buffer);
var server = std.http.Server.init(
    &conn_reader.interface,
    &conn_writer.interface
);

// Client request
var req = try client.request(.GET, uri, .{});
defer req.deinit();
try req.sendBodiless();

var response = try req.receiveHead(&.{});
var reader_buffer: [100]u8 = undefined;
const body_reader = response.reader(&reader_buffer);
```

---

## Notable Stdlib Changes

### Removed in 0.15

| Module | Status | Alternative |
|--------|--------|-------------|
| `std.io` (generic readers/writers) | Deprecated | `std.Io.Reader`, `std.Io.Writer` |
| `usingnamespace` | Removed | Explicit imports or zero-bit fields |
| `async`/`await` keywords | Removed | `std.Io` interfaces (future) |
| `std.ArrayList` | Deprecated | `std.array_list.Managed` |
| `std.fifo.LinearFifo` | Removed | `std.Io.Reader`/`std.Io.Writer` |
| `std.RingBuffer` | Removed | `std.Io.Reader`/`std.Io.Writer` |
| `std.compress.flate.Compress` | Removed | External packages |
| `std.DoublyLinkedList.Node` | Changed | Use struct with `@fieldParentPtr` |

### New/Improved in 0.15

| Module | Feature | Notes |
|--------|---------|-------|
| `std.Io` | New Reader/Writer | Non-generic, buffer in interface |
| `std.fs.File` | `.reader()`, `.writer()` | Returns buffered interface |
| `std.Progress` | `setStatus()` | Terminal progress/status support |
| `std.http.Server` | Stream-only API | No longer depends on `std.net` |
| `std.http.Client` | Simplified API | Stream-based, cleaner signatures |
| `std.crypto.tls` | Stream-based | Only depends on `std.Io` |
| `std.compress.flate` | Restructured | Uses new I/O, container parameter |
| `std.BoundedArray` | New variants | Memory-safe bounded operations |

### Format String Changes

```zig
// BREAKING: {} with type implementing format() now errors
// Must explicitly choose:

// Option 1: Use {f} to call format method
try writer.print("{f}", .{my_type});

// Option 2: Use {any} to skip format method
try writer.print("{any}", .{my_type});

// New shorthand specifiers
try writer.print("{t}", .{my_enum});      // Tag name
try writer.print("{t}", .{my_error});     // Error name
try writer.print("{b64}", .{my_bytes});   // Base64 output
```

---

## Documentation Resources for Agents

These links are optimized for LLM crawling to fetch additional context about Zig 0.15:

### Official Documentation

- **Zig Language Reference**: https://ziglang.org/documentation/0.15.0/
- **Zig Standard Library Docs**: https://ziglang.org/documentation/0.15.0/std/
- **Release Notes**: https://ziglang.org/download/0.15.0/release-notes.html
- **Zig Build System**: https://ziglang.org/learn/build-system/

### Standard Library Modules (Direct Links)

- `std.fs`: https://ziglang.org/documentation/0.15.0/std/src/fs.zig.html
- `std.Io`: https://ziglang.org/documentation/0.15.0/std/src/io.zig.html
- `std.http`: https://ziglang.org/documentation/0.15.0/std/src/http.zig.html
- `std.fmt`: https://ziglang.org/documentation/0.15.0/std/src/fmt.zig.html
- `std.json`: https://ziglang.org/documentation/0.15.0/std/src/json.zig.html
- `std.crypto`: https://ziglang.org/documentation/0.15.0/std/src/crypto.zig.html
- `std.mem`: https://ziglang.org/documentation/0.15.0/std/src/mem.zig.html
- `std.process`: https://ziglang.org/documentation/0.15.0/std/src/process.zig.html

### Learning Resources

- **Getting Started Guide**: https://ziglang.org/learn/getting-started/
- **Tools and Editors**: https://ziglang.org/tools/
- **Community Tools**: https://github.com/search?q=topic%3Azig

### MCP (Model Context Protocol) Server for Zig Docs

If using a context7 MCP server for Zig 0.15 documentation:

```bash
# Initialize context7 with Zig 0.15 docs
# (Configuration depends on your MCP implementation)

# Example with environment variable
export ZIG_DOCS_VERSION=0.15.0
export ZIG_DOCS_URL=https://ziglang.org/documentation/0.15.0/
```

### Community Resources

- **Ziggit Forums**: https://ziggit.dev/ (for questions and discussions)
- **Zig GitHub**: https://github.com/ziglang/zig
- **Zig Issue Tracker**: https://github.com/ziglang/zig/issues

---

## Browsing Zig Source Code

To explore Zig's implementation and source code, use **ripgrep (rg)** for fast searching.

### Locating Zig Installation

```bash
# On POSIX systems (Linux, macOS)
which zig

# On Windows
where zig

# Display Zig version and paths
zig env
```

### Finding Zig Standard Library

```bash
# Locate stdlib directory
ZIG_PATH=$(which zig | xargs dirname)
ZIG_HOME=$(realpath $ZIG_PATH/..)

# List std lib modules
ls -la $ZIG_HOME/lib/zig/std/

# Or use ripgrep to search
rg "pub const Reader" $ZIG_HOME/lib/zig/std/
```

### Using Ripgrep to Search Zig Code

```bash
# Install ripgrep if not present
sudo apt install ripgrep  # Ubuntu/Debian
brew install ripgrep      # macOS

# Search for Reader implementation
rg "pub const Reader" /path/to/zig/lib/zig/std/

# Find all usages of std.Io.Writer
rg "std\.Io\.Writer" /path/to/zig/lib/zig/std/

# Search with context
rg -C 3 "takeDelimiterExclusive" /path/to/zig/lib/zig/std/

# Search in specific file
rg "fn print" /path/to/zig/lib/zig/std/io.zig

# Case-insensitive search
rg -i "reader" /path/to/zig/lib/zig/std/

# Regular expression search
rg "pub fn \w+\(.*Writer" /path/to/zig/lib/zig/std/

# Count occurrences
rg "std.Io" --count /path/to/zig/lib/zig/std/

# Show file names only
rg --files-with-matches "Reader" /path/to/zig/lib/zig/std/
```

### Practical Examples

```bash
# Find Reader interface definition
rg "pub const Reader = struct" $ZIG_HOME/lib/zig/std/

# Trace sendFile implementation
rg -A 20 "pub fn sendFile" $ZIG_HOME/lib/zig/std/

# Find format method changes
rg "pub fn format" $ZIG_HOME/lib/zig/std/

# Search for deprecated functions
rg "deprecated" $ZIG_HOME/lib/zig/std/

# Find HTTP client/server implementation
rg "pub const Client" $ZIG_HOME/lib/zig/std/http.zig

# Look for progress bar code
rg "Progress" $ZIG_HOME/lib/zig/std/
```

---

## Getting Help

### Quick Reference

```bash
# Display all Zig commands
zig --help

# Get help for specific command
zig build --help
zig run --help

# Check your Zig installation
zig env

# Format Zig code
zig fmt your_file.zig

# Analyze code for issues
zig build-exe your_file.zig --check

# Generate documentation for your project
zig build-lib your_file.zig --emit-docs
```

### IDE/Editor Integration

- **Zed Editor**: Native Zig support (recommended for your setup)
- **VSCode**: `zigtools.zls` extension with Zig Language Server
- **Neovim**: nvim-lspconfig with `zls`
- **Vim**: vim-zig plugin

### Setting Up ZLS (Zig Language Server)

```bash
# Install ZLS
git clone https://github.com/zigtools/zls
cd zls
zig build -Drelease=fast

# Add to PATH
export PATH=$PATH:$(pwd)/zig-cache/bin

# Configure in your editor (usually automatic)
```

### Debugging Tips

```bash
# Print debug information
std.debug.print("Variable: {any}\n", .{var_name});

# Enable runtime safety checks
zig build-exe --runtime-safety on

# Build with ASAN (AddressSanitizer)
zig build-exe -fsanitize=address

# Use the new UBSan modes
zig build-exe -fsanitize-c=full     # Full UBSan with runtime
zig build-exe -fsanitize-c=trap     # UBSan with traps only
```

### Performance Profiling

```bash
# Build with time reports
zig build --time-report

# Web UI for compilation analysis
zig build --webui

# Profile specific compilation
time zig build-exe your_file.zig
```

---

## Next Steps

1. **Write your first program**: Start with simple I/O using the new Reader/Writer API
2. **Explore the standard library**: Use ripgrep to understand module implementations
3. **Join the community**: Ask questions on Ziggit forums
4. **Read release notes**: Understand all breaking changes before migrating projects
5. **Experiment with new features**: Try the self-hosted backends and incremental compilation

## Resources Summary

| Resource | URL |
|----------|-----|
| Official Zig Site | https://ziglang.org/ |
| Documentation | https://ziglang.org/documentation/0.15.0/ |
| Release Notes | https://ziglang.org/download/0.15.0/release-notes.html |
| GitHub Repository | https://github.com/ziglang/zig |
| Community Forum | https://ziggit.dev/ |
| ZLS (Language Server) | https://github.com/zigtools/zls |

---

**Last Updated**: December 2025  
**Zig Version**: 0.15.x  
**Platform**: Ubuntu Linux (x86_64)
