//! Leela - A Pure Zig PDF Library
//!
//! Leela is a comprehensive PDF manipulation library written in pure Zig.
//! It provides functionality for reading, parsing, and extracting content from PDF files.
//!
//! ## Features
//!
//! - **PDF Parsing**: Parse PDF documents including objects, streams, and cross-reference tables
//! - **Text Extraction**: Extract text content from PDF pages
//! - **Metadata Access**: Read document metadata (title, author, subject, keywords, etc.)
//! - **Annotation Extraction**: Extract annotations in XML format
//! - **Page Operations**: Count pages, extract specific pages
//! - **Image Extraction**: Extract embedded images from PDFs
//!
//! ## Example Usage
//!
//! ```zig
//! const std = @import("std");
//! const leela = @import("leela");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!     const allocator = gpa.allocator();
//!
//!     // Open a PDF document
//!     var doc = try leela.Document.openFile(allocator, "example.pdf");
//!     defer doc.deinit();
//!
//!     // Get page count
//!     const page_count = doc.getPageCount();
//!     std.debug.print("Pages: {d}\n", .{page_count});
//!
//!     // Extract text from page 0
//!     const text = try doc.extractText(allocator, 0);
//!     defer allocator.free(text);
//!     std.debug.print("Text: {s}\n", .{text});
//! }
//! ```
//!
//! ## Installation
//!
//! Add Leela to your project using `zig fetch`:
//!
//! ```bash
//! zig fetch --save git+https://github.com/bkataru/Leela
//! ```
//!
//! Then in your `build.zig`:
//!
//! ```zig
//! const leela_dep = b.dependency("leela", .{
//!     .target = target,
//!     .optimize = optimize,
//! });
//! exe.root_module.addImport("leela", leela_dep.module("leela"));
//! ```

const std = @import("std");

// Re-export public modules
pub const pdf = @import("pdf/parser.zig");
pub const Document = @import("document.zig").Document;
pub const Metadata = @import("document.zig").Metadata;
pub const Annotation = @import("annotations.zig").Annotation;
pub const AnnotationType = @import("annotations.zig").AnnotationType;
pub const Rectangle = @import("annotations.zig").Rectangle;
pub const Color = @import("annotations.zig").Color;

// Version information
pub const version = "1.0.0";
pub const zig_version = "0.15.0";

/// Error types for PDF operations
pub const Error = error{
    /// The file is not a valid PDF
    InvalidPdf,
    /// The PDF version is not supported
    UnsupportedVersion,
    /// Failed to parse a PDF object
    ParseError,
    /// The cross-reference table is invalid or corrupt
    InvalidXref,
    /// The specified page number is out of bounds
    PageOutOfBounds,
    /// Failed to decode a stream
    StreamDecodeError,
    /// The file could not be opened
    FileOpenError,
    /// Memory allocation failed
    OutOfMemory,
    /// An I/O error occurred
    IoError,
    /// The PDF is encrypted and cannot be read
    EncryptedPdf,
    /// An object reference could not be resolved
    InvalidObjectReference,
    /// The stream filter is not supported
    UnsupportedFilter,
    /// End of stream reached unexpectedly
    EndOfStream,
};

test {
    std.testing.refAllDecls(@This());
}
