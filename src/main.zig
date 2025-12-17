//! Leela CLI - A PDF manipulation tool
//!
//! Usage: leela <command> [options] <input.pdf> [output]
//!
//! Commands:
//!   annots      - Extract annotations in XML format
//!   data        - Display PDF metadata
//!   help        - Show help message
//!   pages       - Extract pages or show page count
//!   text        - Extract text content
//!   version     - Show version information

const std = @import("std");
const leela = @import("leela");

const version_string = "1.0.0";
const copyright = "Copyright (C) 2024  Leela Contributors (original by Jesse McClure)";

/// Available commands
const Command = enum {
    annots,
    data,
    help,
    pages,
    text,
    version,

    fn fromString(s: []const u8) ?Command {
        // Support partial matching like the original
        const commands = [_]struct { name: []const u8, cmd: Command }{
            .{ .name = "annots", .cmd = .annots },
            .{ .name = "annotations", .cmd = .annots },
            .{ .name = "data", .cmd = .data },
            .{ .name = "help", .cmd = .help },
            .{ .name = "pages", .cmd = .pages },
            .{ .name = "text", .cmd = .text },
            .{ .name = "version", .cmd = .version },
        };

        for (commands) |entry| {
            if (s.len <= entry.name.len and std.mem.startsWith(u8, entry.name, s)) {
                return entry.cmd;
            }
        }
        return null;
    }
};

/// Options parsed from command line
const Options = struct {
    command: Command = .help,
    input_file: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
    pages: std.ArrayList(usize),
    data_field: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Options {
        return .{
            .pages = .{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *Options) void {
        self.pages.deinit(self.allocator);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = Options.init(allocator);
    defer options.deinit();

    // Parse command line arguments
    if (args.len < 2) {
        printHelp();
        return;
    }

    // First argument is the command
    options.command = Command.fromString(args[1]) orelse {
        printError("Unknown command: {s}", .{args[1]});
        return;
    };

    // Handle help and version immediately
    if (options.command == .help) {
        printHelp();
        return;
    }
    if (options.command == .version) {
        printVersion();
        return;
    }

    // Parse remaining arguments
    var i: usize = 2;
    var in_page_range = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg[0] == '[') {
            in_page_range = true;
            // Check if there's a number after the bracket
            if (arg.len > 1) {
                if (std.fmt.parseInt(usize, arg[1..], 10)) |page| {
                    try options.pages.append(allocator, page);
                } else |_| {}
            }
        } else if (arg[0] == ']') {
            in_page_range = false;
        } else if (in_page_range) {
            // Parse page number
            if (std.fmt.parseInt(usize, arg, 10)) |page| {
                try options.pages.append(allocator, page);
            } else |_| {
                // Check for closing bracket
                if (arg[arg.len - 1] == ']') {
                    in_page_range = false;
                    if (arg.len > 1) {
                        if (std.fmt.parseInt(usize, arg[0 .. arg.len - 1], 10)) |page| {
                            try options.pages.append(allocator, page);
                        } else |_| {}
                    }
                }
            }
        } else if (options.input_file == null) {
            options.input_file = arg;
        } else if (options.output_file == null) {
            options.output_file = arg;
        }
    }

    // Validate input file
    if (options.input_file == null) {
        printError("No input file specified", .{});
        return;
    }

    // Execute command
    executeCommand(&options, allocator) catch |err| {
        printError("Error: {s}", .{@errorName(err)});
    };
}

fn executeCommand(options: *Options, allocator: std.mem.Allocator) !void {
    // Open the PDF document
    var doc = try leela.Document.openFile(allocator, options.input_file.?);
    defer doc.deinit();

    // If no pages specified, use all pages
    if (options.pages.items.len == 0) {
        const page_count = doc.getPageCount();
        for (0..page_count) |i| {
            try options.pages.append(allocator, i);
        }
    }

    // Get stdout for output  
    const stdout_file = std.fs.File.stdout();

    switch (options.command) {
        .annots => try cmdAnnots(&doc, options, stdout_file, allocator),
        .data => try cmdData(&doc, options, stdout_file),
        .pages => try cmdPages(&doc, options, stdout_file),
        .text => try cmdText(&doc, options, stdout_file, allocator),
        .help => printHelp(),
        .version => printVersion(),
    }
}

fn cmdAnnots(doc: *leela.Document, options: *Options, stdout: std.fs.File, allocator: std.mem.Allocator) !void {
    for (options.pages.items) |page_num| {
        if (page_num >= doc.getPageCount()) continue;

        const annots = try doc.getAnnotations(allocator, page_num);
        defer allocator.free(annots);

        for (annots) |annot| {
            const xml = try annot.toXml(allocator);
            defer allocator.free(xml);
            _ = try stdout.write(xml);
        }
    }
}

fn cmdData(doc: *leela.Document, options: *Options, stdout: std.fs.File) !void {
    var buf: [1024]u8 = undefined;

    if (options.output_file) |field| {
        // Get specific field
        if (doc.getMetadataField(field)) |value| {
            const output = std.fmt.bufPrint(&buf, "{s}\n", .{value}) catch return;
            _ = try stdout.write(output);
        }
    } else {
        // Print all metadata
        var output = std.fmt.bufPrint(&buf, "PDF Version: {s}\n", .{doc.getVersion()}) catch return;
        _ = try stdout.write(output);

        output = std.fmt.bufPrint(&buf, "Page Count: {d}\n", .{doc.getPageCount()}) catch return;
        _ = try stdout.write(output);

        const fields = [_]struct { name: []const u8, label: []const u8 }{
            .{ .name = "title", .label = "Title" },
            .{ .name = "author", .label = "Author" },
            .{ .name = "subject", .label = "Subject" },
            .{ .name = "keywords", .label = "Keywords" },
            .{ .name = "creator", .label = "Creator" },
            .{ .name = "producer", .label = "Producer" },
            .{ .name = "created", .label = "Created" },
            .{ .name = "modified", .label = "Modified" },
        };

        for (fields) |f| {
            if (doc.getMetadataField(f.name)) |value| {
                output = std.fmt.bufPrint(&buf, "{s}: {s}\n", .{ f.label, value }) catch continue;
                _ = try stdout.write(output);
            }
        }
    }
}

fn cmdPages(doc: *leela.Document, options: *Options, stdout: std.fs.File) !void {
    var buf: [256]u8 = undefined;

    if (options.pages.items.len == 0 or
        (options.pages.items.len == doc.getPageCount()))
    {
        // Just print page count
        const output = std.fmt.bufPrint(&buf, "{d}\n", .{doc.getPageCount()}) catch return;
        _ = try stdout.write(output);
    } else {
        // Print info about selected pages
        for (options.pages.items) |page_num| {
            if (page_num >= doc.getPageCount()) continue;

            const info = try doc.getPageInfo(page_num);
            var output = std.fmt.bufPrint(&buf, "Page {d}: {d:.0}x{d:.0} pts", .{ page_num + 1, info.width, info.height }) catch continue;
            _ = try stdout.write(output);
            if (info.rotation != 0) {
                output = std.fmt.bufPrint(&buf, " (rotated {d}°)", .{info.rotation}) catch continue;
                _ = try stdout.write(output);
            }
            _ = try stdout.write("\n");
        }
    }
}

fn cmdText(doc: *leela.Document, options: *Options, stdout: std.fs.File, allocator: std.mem.Allocator) !void {
    for (options.pages.items) |page_num| {
        if (page_num >= doc.getPageCount()) continue;

        const text = try doc.extractText(allocator, page_num);
        defer allocator.free(text);

        _ = try stdout.write(text);
        _ = try stdout.write("\n");
    }
}

fn printHelp() void {
    const help_text =
        \\Leela v{s} {s}
        \\A pure Zig PDF manipulation library and CLI tool.
        \\This program comes with ABSOLUTELY NO WARRANTY.
        \\This is free software under the GPLv3 license.
        \\
        \\USAGE: leela <command> [ n1 n2 ... nN ] <pdf> [output]
        \\
        \\  command     Command from the list below
        \\  n1...nN     Page range in square brackets (default=all)
        \\  pdf         Input PDF file
        \\  output      Output type or filename
        \\
        \\COMMANDS:
        \\  annots      Extract annotations in XML format
        \\  data        Display PDF metadata
        \\  help        Show this help message
        \\  pages       Show page count or extract pages
        \\  text        Extract text content
        \\  version     Show version information
        \\
        \\EXAMPLES:
        \\  leela pages document.pdf
        \\  leela text [ 0 1 2 ] document.pdf
        \\  leela annots document.pdf
        \\  leela data document.pdf title
        \\
        \\For more information, see the README or online documentation.
        \\
    ;
    std.debug.print(help_text, .{ version_string, copyright });
}

fn printVersion() void {
    std.debug.print("Leela v{s}\n", .{version_string});
    std.debug.print("Built with Zig {s}\n", .{leela.zig_version});
    std.debug.print("{s}\n", .{copyright});
}

fn printError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("Error: " ++ fmt ++ "\n", args);
    std.debug.print("Run 'leela help' for usage information.\n", .{});
}

// Tests
test "Command.fromString" {
    try std.testing.expect(Command.fromString("help") == .help);
    try std.testing.expect(Command.fromString("h") == .help);
    try std.testing.expect(Command.fromString("text") == .text);
    try std.testing.expect(Command.fromString("t") == .text);
    try std.testing.expect(Command.fromString("annots") == .annots);
    try std.testing.expect(Command.fromString("annotations") == .annots);
    try std.testing.expect(Command.fromString("xyz") == null);
}

test "Options init and deinit" {
    var options = Options.init(std.testing.allocator);
    defer options.deinit();

    try options.pages.append(std.testing.allocator, 0);
    try options.pages.append(std.testing.allocator, 1);
    try std.testing.expectEqual(@as(usize, 2), options.pages.items.len);
}
