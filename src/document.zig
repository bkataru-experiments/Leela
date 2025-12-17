//! PDF Document Module
//!
//! This module provides high-level access to PDF documents, including:
//! - Opening and closing PDF files
//! - Accessing document metadata
//! - Extracting text content
//! - Getting page information
//! - Navigating the document structure

const std = @import("std");
const Allocator = std.mem.Allocator;
const pdf = @import("pdf/parser.zig");
const annotations = @import("annotations.zig");

/// PDF Document metadata
pub const Metadata = struct {
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    keywords: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    producer: ?[]const u8 = null,
    creation_date: ?[]const u8 = null,
    modification_date: ?[]const u8 = null,

    pub fn deinit(self: *Metadata, allocator: Allocator) void {
        if (self.title) |t| allocator.free(t);
        if (self.author) |a| allocator.free(a);
        if (self.subject) |s| allocator.free(s);
        if (self.keywords) |k| allocator.free(k);
        if (self.creator) |c| allocator.free(c);
        if (self.producer) |p| allocator.free(p);
        if (self.creation_date) |cd| allocator.free(cd);
        if (self.modification_date) |md| allocator.free(md);
    }
};

/// Page information
pub const PageInfo = struct {
    /// Page width in points (1/72 inch)
    width: f64,
    /// Page height in points (1/72 inch)
    height: f64,
    /// Page rotation in degrees (0, 90, 180, 270)
    rotation: i32,
    /// Page index (0-based)
    index: usize,
};

/// Represents an open PDF document
pub const Document = struct {
    allocator: Allocator,
    data: []const u8,
    owns_data: bool,
    parser: pdf.Parser,
    xref: pdf.Xref,
    trailer: pdf.Dictionary,
    catalog: ?pdf.Dictionary = null,
    page_count: ?usize = null,
    pages: std.ArrayList(pdf.ObjectRef),
    version: []const u8,
    info_dict: ?pdf.Dictionary = null,

    /// Open a PDF document from a file path
    pub fn openFile(allocator: Allocator, path: []const u8) !Document {
        const file = std.fs.cwd().openFile(path, .{}) catch return error.FileOpenError;
        defer file.close();

        const stat = file.stat() catch return error.FileOpenError;
        const size = stat.size;

        const data = allocator.alloc(u8, size) catch return error.OutOfMemory;
        errdefer allocator.free(data);

        const bytes_read = file.readAll(data) catch return error.IoError;
        if (bytes_read != size) {
            return error.IoError;
        }

        return openMemory(allocator, data, true);
    }

    /// Open a PDF document from memory
    /// If `owns_data` is true, the document will free the data when closed
    pub fn openMemory(allocator: Allocator, data: []const u8, owns_data: bool) !Document {
        var parser = pdf.Parser.init(allocator, data);

        // Parse header
        const version = parser.parseHeader() catch return error.InvalidPdf;

        // Find startxref
        const startxref = try parser.findStartXref();

        // Parse xref table
        var xref = try parser.parseXref(startxref);
        errdefer xref.deinit();

        // Find and parse trailer
        var trailer = (try parser.findTrailer()) orelse return error.InvalidPdf;
        errdefer trailer.deinit(allocator);

        // Get catalog (root object)
        var catalog: ?pdf.Dictionary = null;
        if (trailer.getReference("Root")) |root_ref| {
            const entry = xref.get(root_ref.obj_num) orelse return error.InvalidObjectReference;
            const result = try parser.parseIndirectObject(entry.offset);
            var obj = result.obj;
            catalog = obj.asDictionary();
        }

        // Get info dictionary
        var info_dict: ?pdf.Dictionary = null;
        if (trailer.getReference("Info")) |info_ref| {
            const entry = xref.get(info_ref.obj_num);
            if (entry) |e| {
                const result = parser.parseIndirectObject(e.offset) catch null;
                if (result) |r| {
                    var obj = r.obj;
                    info_dict = obj.asDictionary();
                }
            }
        }

        var doc = Document{
            .allocator = allocator,
            .data = data,
            .owns_data = owns_data,
            .parser = parser,
            .xref = xref,
            .trailer = trailer,
            .catalog = catalog,
            .pages = std.ArrayList(pdf.ObjectRef){},
            .version = version,
            .info_dict = info_dict,
        };

        // Build page list
        try doc.buildPageList();

        return doc;
    }

    /// Close the document and free all resources
    pub fn deinit(self: *Document) void {
        self.pages.deinit(self.allocator);
        self.xref.deinit();
        if (self.owns_data) {
            self.allocator.free(self.data);
        }
    }

    /// Get the number of pages in the document
    pub fn getPageCount(self: *Document) usize {
        if (self.page_count) |count| {
            return count;
        }
        return self.pages.items.len;
    }

    /// Get the PDF version string (e.g., "1.7")
    pub fn getVersion(self: Document) []const u8 {
        return self.version;
    }

    /// Get document metadata
    pub fn getMetadata(self: *Document) !Metadata {
        var metadata = Metadata{};

        if (self.info_dict) |info| {
            if (info.getString("Title")) |t| {
                metadata.title = try self.allocator.dupe(u8, t);
            }
            if (info.getString("Author")) |a| {
                metadata.author = try self.allocator.dupe(u8, a);
            }
            if (info.getString("Subject")) |s| {
                metadata.subject = try self.allocator.dupe(u8, s);
            }
            if (info.getString("Keywords")) |k| {
                metadata.keywords = try self.allocator.dupe(u8, k);
            }
            if (info.getString("Creator")) |c| {
                metadata.creator = try self.allocator.dupe(u8, c);
            }
            if (info.getString("Producer")) |p| {
                metadata.producer = try self.allocator.dupe(u8, p);
            }
            if (info.getString("CreationDate")) |cd| {
                metadata.creation_date = try self.allocator.dupe(u8, cd);
            }
            if (info.getString("ModDate")) |md| {
                metadata.modification_date = try self.allocator.dupe(u8, md);
            }
        }

        return metadata;
    }

    /// Get a specific metadata field by name
    pub fn getMetadataField(self: *Document, field: []const u8) ?[]const u8 {
        if (self.info_dict) |info| {
            if (std.mem.eql(u8, field, "title")) {
                return info.getString("Title");
            } else if (std.mem.eql(u8, field, "author")) {
                return info.getString("Author");
            } else if (std.mem.eql(u8, field, "subject")) {
                return info.getString("Subject");
            } else if (std.mem.eql(u8, field, "keywords")) {
                return info.getString("Keywords");
            } else if (std.mem.eql(u8, field, "creator")) {
                return info.getString("Creator");
            } else if (std.mem.eql(u8, field, "producer")) {
                return info.getString("Producer");
            } else if (std.mem.eql(u8, field, "created")) {
                return info.getString("CreationDate");
            } else if (std.mem.eql(u8, field, "modified")) {
                return info.getString("ModDate");
            }
        }
        return null;
    }

    /// Get information about a specific page
    pub fn getPageInfo(self: *Document, page_num: usize) !PageInfo {
        if (page_num >= self.pages.items.len) {
            return error.PageOutOfBounds;
        }

        const page_ref = self.pages.items[page_num];
        const page_dict = try self.resolvePageDict(page_ref);

        // Get MediaBox (required)
        var width: f64 = 612; // Default letter size
        var height: f64 = 792;
        var rotation: i32 = 0;

        if (page_dict.getArray("MediaBox")) |media_box| {
            if (media_box.len >= 4) {
                const x1 = media_box[0].asReal() orelse 0;
                const y1 = media_box[1].asReal() orelse 0;
                const x2 = media_box[2].asReal() orelse 612;
                const y2 = media_box[3].asReal() orelse 792;
                width = x2 - x1;
                height = y2 - y1;
            }
        }

        if (page_dict.getInteger("Rotate")) |rot| {
            rotation = @intCast(rot);
        }

        return .{
            .width = width,
            .height = height,
            .rotation = rotation,
            .index = page_num,
        };
    }

    /// Extract text content from a specific page
    pub fn extractText(self: *Document, allocator: Allocator, page_num: usize) ![]const u8 {
        if (page_num >= self.pages.items.len) {
            return error.PageOutOfBounds;
        }

        const page_ref = self.pages.items[page_num];
        const page_dict = try self.resolvePageDict(page_ref);

        // Get Contents stream(s)
        const contents_obj = page_dict.get("Contents") orelse {
            return try allocator.dupe(u8, "");
        };

        var text = std.ArrayList(u8){};
        errdefer text.deinit(allocator);

        try self.extractTextFromContents(&text, contents_obj, allocator);

        return try text.toOwnedSlice(allocator);
    }

    /// Extract text from all pages
    pub fn extractAllText(self: *Document, allocator: Allocator) ![]const u8 {
        var text = std.ArrayList(u8){};
        errdefer text.deinit(allocator);

        for (0..self.pages.items.len) |i| {
            const page_text = try self.extractText(allocator, i);
            defer allocator.free(page_text);
            try text.appendSlice(allocator, page_text);
            try text.append(allocator, '\n');
        }

        return try text.toOwnedSlice(allocator);
    }

    /// Get annotations from a specific page
    pub fn getAnnotations(self: *Document, allocator: Allocator, page_num: usize) ![]annotations.Annotation {
        if (page_num >= self.pages.items.len) {
            return error.PageOutOfBounds;
        }

        const page_ref = self.pages.items[page_num];
        const page_dict = try self.resolvePageDict(page_ref);

        var annot_list = std.ArrayList(annotations.Annotation){};
        errdefer annot_list.deinit(allocator);

        // Get Annots array
        const annots_obj = page_dict.get("Annots") orelse {
            return try annot_list.toOwnedSlice(allocator);
        };

        // Handle array of references
        if (annots_obj.asArray()) |annots_array| {
            for (annots_array, 0..) |annot_ref_obj, index| {
                const annot_ref = annot_ref_obj.asReference() orelse continue;
                const annot_dict = self.resolveDict(annot_ref) catch continue;

                var annot = annotations.Annotation{
                    .page = page_num,
                    .index = index,
                };

                // Parse annotation type
                if (annot_dict.getName("Subtype")) |subtype| {
                    annot.annot_type = annotations.AnnotationType.fromName(subtype);
                }

                // Parse rectangle
                if (annot_dict.getArray("Rect")) |rect_arr| {
                    if (rect_arr.len >= 4) {
                        annot.rect = .{
                            .x1 = rect_arr[0].asReal() orelse 0,
                            .y1 = rect_arr[1].asReal() orelse 0,
                            .x2 = rect_arr[2].asReal() orelse 0,
                            .y2 = rect_arr[3].asReal() orelse 0,
                        };
                    }
                }

                // Parse name
                if (annot_dict.getString("NM")) |name| {
                    annot.name = try allocator.dupe(u8, name);
                }

                // Parse contents
                if (annot_dict.getString("Contents")) |contents| {
                    annot.contents = try allocator.dupe(u8, contents);
                }

                // Parse color
                if (annot_dict.getArray("C")) |color_arr| {
                    if (color_arr.len >= 3) {
                        annot.color = .{
                            .r = @intFromFloat((color_arr[0].asReal() orelse 0) * 255),
                            .g = @intFromFloat((color_arr[1].asReal() orelse 0) * 255),
                            .b = @intFromFloat((color_arr[2].asReal() orelse 0) * 255),
                        };
                    }
                }

                // Parse markup specific fields
                if (annot_dict.getString("T")) |label| {
                    annot.label = try allocator.dupe(u8, label);
                }
                if (annot_dict.getString("Subj")) |subject| {
                    annot.subject = try allocator.dupe(u8, subject);
                }

                try annot_list.append(allocator, annot);
            }
        }

        return try annot_list.toOwnedSlice(allocator);
    }

    /// Get all annotations from all pages
    pub fn getAllAnnotations(self: *Document, allocator: Allocator) ![]annotations.Annotation {
        var all_annots = std.ArrayList(annotations.Annotation){};
        errdefer {
            for (all_annots.items) |*a| {
                a.deinit(allocator);
            }
            all_annots.deinit(allocator);
        }

        for (0..self.pages.items.len) |i| {
            const page_annots = try self.getAnnotations(allocator, i);
            defer allocator.free(page_annots);

            for (page_annots) |annot| {
                try all_annots.append(allocator, annot);
            }
        }

        return try all_annots.toOwnedSlice(allocator);
    }

    /// Check if the PDF contains any attachments
    pub fn hasAttachments(self: *Document) bool {
        if (self.catalog) |catalog| {
            if (catalog.get("Names")) |names_ref| {
                if (names_ref.asReference()) |ref| {
                    const names_dict = self.resolveDict(ref) catch return false;
                    return names_dict.contains("EmbeddedFiles");
                }
            }
        }
        return false;
    }

    // Private helper methods

    fn buildPageList(self: *Document) !void {
        if (self.catalog == null) return;

        const pages_obj = self.catalog.?.get("Pages") orelse return;
        const pages_ref = pages_obj.asReference() orelse return;

        try self.collectPages(pages_ref);
        self.page_count = self.pages.items.len;
    }

    fn collectPages(self: *Document, node_ref: pdf.ObjectRef) !void {
        const node_dict = try self.resolveDict(node_ref);

        const type_name = node_dict.getName("Type") orelse return;

        if (std.mem.eql(u8, type_name, "Pages")) {
            // This is a Pages node, recurse into Kids
            const kids_obj = node_dict.get("Kids") orelse return;
            const kids = kids_obj.asArray() orelse return;

            for (kids) |kid| {
                const kid_ref = kid.asReference() orelse continue;
                try self.collectPages(kid_ref);
            }
        } else if (std.mem.eql(u8, type_name, "Page")) {
            // This is a Page leaf node
            try self.pages.append(self.allocator, node_ref);
        }
    }

    fn resolveDict(self: *Document, ref: pdf.ObjectRef) !pdf.Dictionary {
        const entry = self.xref.get(ref.obj_num) orelse return error.InvalidObjectReference;
        const result = try self.parser.parseIndirectObject(entry.offset);
        return result.obj.asDictionary() orelse error.ParseError;
    }

    fn resolvePageDict(self: *Document, ref: pdf.ObjectRef) !pdf.Dictionary {
        return self.resolveDict(ref);
    }

    fn extractTextFromContents(self: *Document, text: *std.ArrayList(u8), contents_obj: pdf.Object, allocator: Allocator) !void {
        if (contents_obj.asReference()) |ref| {
            // Single content stream
            try self.extractTextFromStream(text, ref, allocator);
        } else if (contents_obj.asArray()) |arr| {
            // Array of content streams
            for (arr) |item| {
                if (item.asReference()) |ref| {
                    try self.extractTextFromStream(text, ref, allocator);
                }
            }
        }
    }

    fn extractTextFromStream(self: *Document, text: *std.ArrayList(u8), ref: pdf.ObjectRef, allocator: Allocator) !void {
        const entry = self.xref.get(ref.obj_num) orelse return error.InvalidObjectReference;
        const result = try self.parser.parseIndirectObject(entry.offset);

        var stream = result.obj.asStream() orelse return;
        const stream_data = try stream.getDecodedData(self.allocator);

        // Parse content stream and extract text
        try parseContentStream(text, stream_data, allocator);
    }
};

/// Parse a PDF content stream and extract text
fn parseContentStream(text: *std.ArrayList(u8), data: []const u8, allocator: std.mem.Allocator) !void {
    var pos: usize = 0;
    var in_text = false;

    while (pos < data.len) {
        // Skip whitespace
        while (pos < data.len and (data[pos] == ' ' or data[pos] == '\n' or
            data[pos] == '\r' or data[pos] == '\t'))
        {
            pos += 1;
        }
        if (pos >= data.len) break;

        const c = data[pos];

        // Check for BT (begin text)
        if (pos + 1 < data.len and data[pos] == 'B' and data[pos + 1] == 'T') {
            if (pos + 2 >= data.len or isWhitespaceOrDelim(data[pos + 2])) {
                in_text = true;
                pos += 2;
                continue;
            }
        }

        // Check for ET (end text)
        if (pos + 1 < data.len and data[pos] == 'E' and data[pos + 1] == 'T') {
            if (pos + 2 >= data.len or isWhitespaceOrDelim(data[pos + 2])) {
                in_text = false;
                pos += 2;
                continue;
            }
        }

        // Look for Tj or TJ operators (show text)
        if (in_text) {
            // Check for Tj operator
            if (pos + 1 < data.len and data[pos] == 'T' and data[pos + 1] == 'j') {
                if (pos + 2 >= data.len or isWhitespaceOrDelim(data[pos + 2])) {
                    pos += 2;
                    continue;
                }
            }

            // Check for TJ operator
            if (pos + 1 < data.len and data[pos] == 'T' and data[pos + 1] == 'J') {
                if (pos + 2 >= data.len or isWhitespaceOrDelim(data[pos + 2])) {
                    pos += 2;
                    continue;
                }
            }

            // Check for ' operator (move to next line and show text)
            if (c == '\'' and (pos + 1 >= data.len or isWhitespaceOrDelim(data[pos + 1]))) {
                try text.append(allocator, '\n');
                pos += 1;
                continue;
            }

            // Check for " operator (set spacing and show text)
            if (c == '"' and (pos + 1 >= data.len or isWhitespaceOrDelim(data[pos + 1]))) {
                pos += 1;
                continue;
            }
        }

        // Parse string literals for text extraction
        if (c == '(') {
            const str_start = pos + 1;
            pos += 1;
            var depth: usize = 1;

            while (pos < data.len and depth > 0) {
                if (data[pos] == '\\' and pos + 1 < data.len) {
                    pos += 2; // Skip escaped char
                } else if (data[pos] == '(') {
                    depth += 1;
                    pos += 1;
                } else if (data[pos] == ')') {
                    depth -= 1;
                    if (depth > 0) pos += 1;
                } else {
                    pos += 1;
                }
            }

            if (in_text) {
                // Extract the string content
                const str_end = pos;
                const str_content = data[str_start..str_end];
                try decodeStringToText(text, str_content, allocator);
            }

            if (pos < data.len) pos += 1; // Skip closing )
            continue;
        }

        // Parse hex strings
        if (c == '<' and pos + 1 < data.len and data[pos + 1] != '<') {
            pos += 1;
            const hex_start = pos;

            while (pos < data.len and data[pos] != '>') {
                pos += 1;
            }

            if (in_text) {
                const hex_content = data[hex_start..pos];
                try decodeHexToText(text, hex_content, allocator);
            }

            if (pos < data.len) pos += 1; // Skip >
            continue;
        }

        // Parse arrays for TJ operator
        if (c == '[') {
            pos += 1;
            while (pos < data.len and data[pos] != ']') {
                // Skip whitespace
                while (pos < data.len and (data[pos] == ' ' or data[pos] == '\n' or
                    data[pos] == '\r' or data[pos] == '\t'))
                {
                    pos += 1;
                }
                if (pos >= data.len or data[pos] == ']') break;

                if (data[pos] == '(') {
                    const str_start = pos + 1;
                    pos += 1;
                    var depth: usize = 1;

                    while (pos < data.len and depth > 0) {
                        if (data[pos] == '\\' and pos + 1 < data.len) {
                            pos += 2;
                        } else if (data[pos] == '(') {
                            depth += 1;
                            pos += 1;
                        } else if (data[pos] == ')') {
                            depth -= 1;
                            if (depth > 0) pos += 1;
                        } else {
                            pos += 1;
                        }
                    }

                    if (in_text) {
                        const str_content = data[str_start..pos];
                        try decodeStringToText(text, str_content, allocator);
                    }

                    if (pos < data.len) pos += 1;
                } else if (data[pos] == '<') {
                    pos += 1;
                    const hex_start = pos;

                    while (pos < data.len and data[pos] != '>') {
                        pos += 1;
                    }

                    if (in_text) {
                        const hex_content = data[hex_start..pos];
                        try decodeHexToText(text, hex_content, allocator);
                    }

                    if (pos < data.len) pos += 1;
                } else {
                    // Skip number (spacing adjustment)
                    while (pos < data.len and !isWhitespaceOrDelim(data[pos]) and data[pos] != ']') {
                        pos += 1;
                    }
                }
            }

            if (pos < data.len) pos += 1; // Skip ]
            continue;
        }

        // Skip other tokens
        while (pos < data.len and !isWhitespaceOrDelim(data[pos])) {
            pos += 1;
        }
    }
}

fn isWhitespaceOrDelim(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t' or
        c == '(' or c == ')' or c == '<' or c == '>' or
        c == '[' or c == ']' or c == '/' or c == '%';
}

fn decodeStringToText(text: *std.ArrayList(u8), str: []const u8, allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < str.len) {
        if (str[i] == '\\' and i + 1 < str.len) {
            i += 1;
            switch (str[i]) {
                'n' => try text.append(allocator, '\n'),
                'r' => try text.append(allocator, '\r'),
                't' => try text.append(allocator, '\t'),
                'b' => try text.append(allocator, 0x08),
                'f' => try text.append(allocator, 0x0C),
                '(' => try text.append(allocator, '('),
                ')' => try text.append(allocator, ')'),
                '\\' => try text.append(allocator, '\\'),
                '0'...'7' => {
                    var octal: u8 = str[i] - '0';
                    if (i + 1 < str.len and str[i + 1] >= '0' and str[i + 1] <= '7') {
                        i += 1;
                        octal = octal * 8 + (str[i] - '0');
                        if (i + 1 < str.len and str[i + 1] >= '0' and str[i + 1] <= '7') {
                            i += 1;
                            octal = octal * 8 + (str[i] - '0');
                        }
                    }
                    if (octal >= 32 and octal < 127) {
                        try text.append(allocator, octal);
                    }
                },
                else => {},
            }
            i += 1;
        } else if (str[i] >= 32 and str[i] < 127) {
            try text.append(allocator, str[i]);
            i += 1;
        } else {
            i += 1;
        }
    }
}

fn decodeHexToText(text: *std.ArrayList(u8), hex: []const u8, allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i + 1 < hex.len) {
        // Skip whitespace
        while (i < hex.len and (hex[i] == ' ' or hex[i] == '\n' or hex[i] == '\r' or hex[i] == '\t')) {
            i += 1;
        }
        if (i + 1 >= hex.len) break;

        const h1 = hexDigit(hex[i]) orelse {
            i += 1;
            continue;
        };
        const h2 = hexDigit(hex[i + 1]) orelse {
            i += 2;
            continue;
        };

        const byte = (@as(u8, h1) << 4) | @as(u8, h2);
        if (byte >= 32 and byte < 127) {
            try text.append(allocator, byte);
        }
        i += 2;
    }
}

fn hexDigit(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @truncate(c - '0'),
        'a'...'f' => @truncate(c - 'a' + 10),
        'A'...'F' => @truncate(c - 'A' + 10),
        else => null,
    };
}

// Tests
test "Document page count" {
    // Create a minimal PDF in memory for testing
    const minimal_pdf =
        \\%PDF-1.4
        \\1 0 obj
        \\<< /Type /Catalog /Pages 2 0 R >>
        \\endobj
        \\2 0 obj
        \\<< /Type /Pages /Kids [3 0 R] /Count 1 >>
        \\endobj
        \\3 0 obj
        \\<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>
        \\endobj
        \\xref
        \\0 4
        \\0000000000 65535 f 
        \\0000000009 00000 n 
        \\0000000058 00000 n 
        \\0000000115 00000 n 
        \\trailer
        \\<< /Size 4 /Root 1 0 R >>
        \\startxref
        \\200
        \\%%EOF
    ;

    // This test is a placeholder - full integration testing requires valid PDF files
    _ = minimal_pdf;
}
