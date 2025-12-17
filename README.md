# Leela

A pure Zig PDF manipulation library and CLI tool, originally inspired by the C leela project that was a CLI frontend for the poppler-glib library.

This is a complete rewrite in Zig 0.15, providing a clean, dependency-free PDF library.

## Features

- **PDF Parsing**: Parse PDF documents including objects, streams, and cross-reference tables
- **Text Extraction**: Extract text content from PDF pages
- **Metadata Access**: Read document metadata (title, author, subject, keywords, etc.)
- **Annotation Extraction**: Extract annotations in XML format
- **Page Information**: Get page count, dimensions, and rotation

## Installation

### Using `zig fetch` (Recommended)

Add Leela to your project:

```bash
zig fetch --save git+https://github.com/bkataru/Leela
```

Then in your `build.zig`, add the dependency:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add leela dependency
    const leela_dep = b.dependency("leela", .{
        .target = target,
        .optimize = optimize,
    });
    const leela_mod = leela_dep.module("leela");

    // Create your executable module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("leela", leela_mod);

    const exe = b.addExecutable(.{
        .name = "my-pdf-tool",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
}
```

### Manual Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/bkataru/Leela.git
   ```

2. Build:
   ```bash
   cd Leela
   zig build
   ```

3. Run tests:
   ```bash
   zig build test
   ```

## Library Usage

```zig
const std = @import("std");
const leela = @import("leela");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Open a PDF document
    var doc = try leela.Document.openFile(allocator, "example.pdf");
    defer doc.deinit();

    // Get page count
    const page_count = doc.getPageCount();
    std.debug.print("Pages: {d}\n", .{page_count});

    // Get PDF version
    std.debug.print("Version: {s}\n", .{doc.getVersion()});

    // Extract text from page 0
    const text = try doc.extractText(allocator, 0);
    defer allocator.free(text);
    std.debug.print("Text: {s}\n", .{text});

    // Get page information
    const info = try doc.getPageInfo(0);
    std.debug.print("Page size: {d:.0}x{d:.0} pts\n", .{info.width, info.height});

    // Get metadata
    if (doc.getMetadataField("title")) |title| {
        std.debug.print("Title: {s}\n", .{title});
    }

    // Get annotations
    const annots = try doc.getAnnotations(allocator, 0);
    defer allocator.free(annots);
    for (annots) |annot| {
        const xml = try annot.toXml(allocator);
        defer allocator.free(xml);
        std.debug.print("{s}", .{xml});
    }
}
```

## CLI Usage

```bash
# Show help
leela help

# Get page count
leela pages document.pdf

# Extract text from all pages
leela text document.pdf

# Extract text from specific pages
leela text [ 0 1 2 ] document.pdf

# Get document metadata
leela data document.pdf

# Get specific metadata field
leela data document.pdf title

# Extract annotations as XML
leela annots document.pdf
```

## API Reference

### `leela.Document`

Main structure for working with PDF documents.

#### Methods

- `openFile(allocator, path) !Document` - Open a PDF from a file path
- `openMemory(allocator, data, owns_data) !Document` - Open a PDF from memory
- `deinit()` - Close and free resources
- `getPageCount() usize` - Get number of pages
- `getVersion() []const u8` - Get PDF version string
- `extractText(allocator, page_num) ![]const u8` - Extract text from a page
- `extractAllText(allocator) ![]const u8` - Extract text from all pages
- `getPageInfo(page_num) !PageInfo` - Get page dimensions and rotation
- `getMetadataField(field) ?[]const u8` - Get a specific metadata field
- `getMetadata() !Metadata` - Get all metadata
- `getAnnotations(allocator, page_num) ![]Annotation` - Get page annotations
- `getAllAnnotations(allocator) ![]Annotation` - Get all annotations

### `leela.Annotation`

Represents a PDF annotation.

#### Fields

- `page: usize` - Page number (0-based)
- `index: usize` - Annotation index on page
- `annot_type: AnnotationType` - Type of annotation
- `rect: Rectangle` - Bounding rectangle
- `name: ?[]const u8` - Annotation name
- `contents: ?[]const u8` - Text contents
- `color: ?Color` - Annotation color
- `label: ?[]const u8` - Author label
- `subject: ?[]const u8` - Subject

#### Methods

- `toXml(allocator) ![]const u8` - Convert to XML format
- `deinit(allocator)` - Free allocated memory

### `leela.pdf`

Low-level PDF parsing module for advanced use cases.

## Requirements

- Zig 0.15.0 or later

## License

This project is licensed under the GNU General Public License v3.0 - see the LICENSE file for details.

## Credits

- Original C implementation by Jesse McClure
- Zig rewrite by contributors

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
