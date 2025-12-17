//! PDF Annotation Module
//!
//! This module provides structures and functions for working with PDF annotations.
//! Annotations include text notes, highlights, links, shapes, and other markups.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Annotation types as defined in the PDF specification
pub const AnnotationType = enum {
    text,
    link,
    free_text,
    line,
    square,
    circle,
    polygon,
    polyline,
    highlight,
    underline,
    squiggly,
    strike_out,
    stamp,
    caret,
    ink,
    popup,
    file_attachment,
    sound,
    movie,
    widget,
    screen,
    printer_mark,
    trap_net,
    watermark,
    @"3d",
    unknown,

    /// Convert a PDF subtype name to an AnnotationType
    pub fn fromName(name: []const u8) AnnotationType {
        const map = std.StaticStringMap(AnnotationType).initComptime(.{
            .{ "Text", .text },
            .{ "Link", .link },
            .{ "FreeText", .free_text },
            .{ "Line", .line },
            .{ "Square", .square },
            .{ "Circle", .circle },
            .{ "Polygon", .polygon },
            .{ "PolyLine", .polyline },
            .{ "Highlight", .highlight },
            .{ "Underline", .underline },
            .{ "Squiggly", .squiggly },
            .{ "StrikeOut", .strike_out },
            .{ "Stamp", .stamp },
            .{ "Caret", .caret },
            .{ "Ink", .ink },
            .{ "Popup", .popup },
            .{ "FileAttachment", .file_attachment },
            .{ "Sound", .sound },
            .{ "Movie", .movie },
            .{ "Widget", .widget },
            .{ "Screen", .screen },
            .{ "PrinterMark", .printer_mark },
            .{ "TrapNet", .trap_net },
            .{ "Watermark", .watermark },
            .{ "3D", .@"3d" },
        });
        return map.get(name) orelse .unknown;
    }

    /// Convert an AnnotationType to its PDF name
    pub fn toName(self: AnnotationType) []const u8 {
        return switch (self) {
            .text => "text",
            .link => "link",
            .free_text => "free text",
            .line => "line",
            .square => "square",
            .circle => "circle",
            .polygon => "polygon",
            .polyline => "polyline",
            .highlight => "highlight",
            .underline => "underline",
            .squiggly => "squiggly",
            .strike_out => "strikeout",
            .stamp => "stamp",
            .caret => "caret",
            .ink => "ink",
            .popup => "popup",
            .file_attachment => "file",
            .sound => "sound",
            .movie => "movie",
            .widget => "widget",
            .screen => "screen",
            .printer_mark => "mark",
            .trap_net => "trap net",
            .watermark => "watermark",
            .@"3d" => "3D",
            .unknown => "unknown",
        };
    }
};

/// Rectangle coordinates
pub const Rectangle = struct {
    x1: f64 = 0,
    y1: f64 = 0,
    x2: f64 = 0,
    y2: f64 = 0,

    /// Get the width of the rectangle
    pub fn width(self: Rectangle) f64 {
        return @abs(self.x2 - self.x1);
    }

    /// Get the height of the rectangle
    pub fn height(self: Rectangle) f64 {
        return @abs(self.y2 - self.y1);
    }

    /// Format the rectangle for output
    pub fn format(
        self: Rectangle,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("x1=\"{d:.2}\" y1=\"{d:.2}\" x2=\"{d:.2}\" y2=\"{d:.2}\"", .{ self.x1, self.y1, self.x2, self.y2 });
    }
};

/// RGB Color
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    /// Create a color from floating point values (0.0 to 1.0)
    pub fn fromFloat(r: f64, g: f64, b: f64) Color {
        return .{
            .r = @intFromFloat(@min(1.0, @max(0.0, r)) * 255),
            .g = @intFromFloat(@min(1.0, @max(0.0, g)) * 255),
            .b = @intFromFloat(@min(1.0, @max(0.0, b)) * 255),
        };
    }

    /// Format the color for output
    pub fn format(
        self: Color,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("r=\"{d}\" g=\"{d}\" b=\"{d}\"", .{ self.r, self.g, self.b });
    }
};

/// Represents a PDF annotation
pub const Annotation = struct {
    /// The page number this annotation is on (0-based)
    page: usize = 0,

    /// The index of the annotation on the page
    index: usize = 0,

    /// The type of annotation
    annot_type: AnnotationType = .unknown,

    /// The bounding rectangle of the annotation
    rect: Rectangle = .{},

    /// The annotation name (NM entry)
    name: ?[]const u8 = null,

    /// The text contents of the annotation
    contents: ?[]const u8 = null,

    /// The color of the annotation
    color: ?Color = null,

    /// The label (author) for markup annotations
    label: ?[]const u8 = null,

    /// The subject for markup annotations
    subject: ?[]const u8 = null,

    /// Free allocated memory
    pub fn deinit(self: *Annotation, allocator: Allocator) void {
        if (self.name) |n| allocator.free(n);
        if (self.contents) |c| allocator.free(c);
        if (self.label) |l| allocator.free(l);
        if (self.subject) |s| allocator.free(s);
    }

    /// Output the annotation in XML format (matching the original Leela format)
    pub fn toXml(self: Annotation, allocator: Allocator) ![]const u8 {
        var xml = std.ArrayList(u8){};
        errdefer xml.deinit(allocator);

        try xml.appendSlice(allocator, "<annot page=\"");
        try appendInt(&xml, allocator, self.page);
        try xml.appendSlice(allocator, "\" index=\"");
        try appendInt(&xml, allocator, self.index);
        try xml.appendSlice(allocator, "\" type=\"");
        try xml.appendSlice(allocator, self.annot_type.toName());
        try xml.appendSlice(allocator, "\">\n");

        try xml.appendSlice(allocator, "  <rect x1=\"");
        try appendFloat(&xml, allocator, self.rect.x1);
        try xml.appendSlice(allocator, "\" y1=\"");
        try appendFloat(&xml, allocator, self.rect.y1);
        try xml.appendSlice(allocator, "\" x2=\"");
        try appendFloat(&xml, allocator, self.rect.x2);
        try xml.appendSlice(allocator, "\" y2=\"");
        try appendFloat(&xml, allocator, self.rect.y2);
        try xml.appendSlice(allocator, "\"/>\n");

        if (self.name) |name| {
            try xml.appendSlice(allocator, "  <name>");
            try xml.appendSlice(allocator, name);
            try xml.appendSlice(allocator, "</name>\n");
        }

        if (self.color) |color| {
            try xml.appendSlice(allocator, "  <color r=\"");
            try appendInt(&xml, allocator, color.r);
            try xml.appendSlice(allocator, "\" g=\"");
            try appendInt(&xml, allocator, color.g);
            try xml.appendSlice(allocator, "\" b=\"");
            try appendInt(&xml, allocator, color.b);
            try xml.appendSlice(allocator, "\"/>\n");
        }

        if (self.label) |label| {
            try xml.appendSlice(allocator, "  <label>");
            try xml.appendSlice(allocator, label);
            try xml.appendSlice(allocator, "</label>\n");
        }

        if (self.subject) |subject| {
            try xml.appendSlice(allocator, "  <subject>");
            try xml.appendSlice(allocator, subject);
            try xml.appendSlice(allocator, "</subject>\n");
        }

        if (self.contents) |text| {
            try xml.appendSlice(allocator, "  <text>");
            try xml.appendSlice(allocator, text);
            try xml.appendSlice(allocator, "</text>\n");
        }

        try xml.appendSlice(allocator, "</annot>\n");

        return try xml.toOwnedSlice(allocator);
    }
};

fn appendInt(list: *std.ArrayList(u8), allocator: Allocator, value: anytype) !void {
    var buf: [32]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.OutOfMemory;
    try list.appendSlice(allocator, slice);
}

fn appendFloat(list: *std.ArrayList(u8), allocator: Allocator, value: f64) !void {
    var buf: [64]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{d:.2}", .{value}) catch return error.OutOfMemory;
    try list.appendSlice(allocator, slice);
}

/// Format a list of annotations as XML
pub fn annotationsToXml(allocator: Allocator, annots: []const Annotation) ![]const u8 {
    var xml = std.ArrayList(u8){};
    errdefer xml.deinit(allocator);

    for (annots) |annot| {
        const annot_xml = try annot.toXml(allocator);
        defer allocator.free(annot_xml);
        try xml.appendSlice(allocator, annot_xml);
    }

    return try xml.toOwnedSlice(allocator);
}

// Tests
test "AnnotationType.fromName" {
    try std.testing.expect(AnnotationType.fromName("Text") == .text);
    try std.testing.expect(AnnotationType.fromName("Link") == .link);
    try std.testing.expect(AnnotationType.fromName("Highlight") == .highlight);
    try std.testing.expect(AnnotationType.fromName("Unknown") == .unknown);
}

test "Rectangle dimensions" {
    const rect = Rectangle{ .x1 = 10, .y1 = 20, .x2 = 110, .y2 = 220 };
    try std.testing.expectEqual(@as(f64, 100), rect.width());
    try std.testing.expectEqual(@as(f64, 200), rect.height());
}

test "Color.fromFloat" {
    const color = Color.fromFloat(1.0, 0.5, 0.0);
    try std.testing.expectEqual(@as(u8, 255), color.r);
    try std.testing.expectEqual(@as(u8, 127), color.g);
    try std.testing.expectEqual(@as(u8, 0), color.b);
}

test "Annotation.toXml" {
    var annot = Annotation{
        .page = 0,
        .index = 1,
        .annot_type = .highlight,
        .rect = .{ .x1 = 100, .y1 = 200, .x2 = 300, .y2 = 250 },
    };

    const xml = try annot.toXml(std.testing.allocator);
    defer std.testing.allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "type=\"highlight\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "page=\"0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<rect") != null);
}
