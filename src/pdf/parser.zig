//! PDF Object and Parser Module
//!
//! This module provides low-level PDF parsing functionality including:
//! - PDF object types (null, boolean, integer, real, string, name, array, dictionary, stream)
//! - Cross-reference table parsing
//! - Object stream decoding
//! - Content stream parsing

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Error set for parsing operations
pub const ParseError = error{
    InvalidPdf,
    ParseError,
    InvalidXref,
    EndOfStream,
    OutOfMemory,
};

/// Represents a PDF indirect object reference
pub const ObjectRef = struct {
    obj_num: u32,
    gen_num: u16,

    pub fn eql(self: ObjectRef, other: ObjectRef) bool {
        return self.obj_num == other.obj_num and self.gen_num == other.gen_num;
    }

    pub fn format(
        self: ObjectRef,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d} {d} R", .{ self.obj_num, self.gen_num });
    }
};

/// PDF Object types
pub const Object = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    real: f64,
    string: []const u8,
    hex_string: []const u8,
    name: []const u8,
    array: []Object,
    dictionary: Dictionary,
    stream: Stream,
    reference: ObjectRef,

    pub fn deinit(self: *Object, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .hex_string => |s| allocator.free(s),
            .name => |n| allocator.free(n),
            .array => |arr| {
                for (arr) |*item| {
                    var obj = item.*;
                    obj.deinit(allocator);
                }
                allocator.free(arr);
            },
            .dictionary => |*dict| dict.deinit(allocator),
            .stream => |*s| s.deinit(allocator),
            else => {},
        }
    }

    /// Get the object as a dictionary, or null if not a dictionary
    pub fn asDictionary(self: Object) ?Dictionary {
        return switch (self) {
            .dictionary => |d| d,
            else => null,
        };
    }

    /// Get the object as an array, or null if not an array
    pub fn asArray(self: Object) ?[]Object {
        return switch (self) {
            .array => |a| a,
            else => null,
        };
    }

    /// Get the object as an integer, or null if not an integer
    pub fn asInteger(self: Object) ?i64 {
        return switch (self) {
            .integer => |i| i,
            else => null,
        };
    }

    /// Get the object as a real number, or null if not a real
    pub fn asReal(self: Object) ?f64 {
        return switch (self) {
            .real => |r| r,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    /// Get the object as a string, or null if not a string
    pub fn asString(self: Object) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            .hex_string => |s| s,
            else => null,
        };
    }

    /// Get the object as a name, or null if not a name
    pub fn asName(self: Object) ?[]const u8 {
        return switch (self) {
            .name => |n| n,
            else => null,
        };
    }

    /// Get the object as a boolean, or null if not a boolean
    pub fn asBoolean(self: Object) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }

    /// Get the object as a reference, or null if not a reference
    pub fn asReference(self: Object) ?ObjectRef {
        return switch (self) {
            .reference => |r| r,
            else => null,
        };
    }

    /// Get the object as a stream, or null if not a stream
    pub fn asStream(self: Object) ?Stream {
        return switch (self) {
            .stream => |s| s,
            else => null,
        };
    }
};

/// PDF Dictionary type - a map of names to objects
pub const Dictionary = struct {
    entries: std.StringArrayHashMap(Object),

    pub fn init(allocator: Allocator) Dictionary {
        return .{
            .entries = std.StringArrayHashMap(Object).init(allocator),
        };
    }

    pub fn deinit(self: *Dictionary, allocator: Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            var obj = entry.value_ptr.*;
            obj.deinit(allocator);
        }
        self.entries.deinit();
    }

    pub fn get(self: Dictionary, key: []const u8) ?Object {
        return self.entries.get(key);
    }

    pub fn put(self: *Dictionary, allocator: Allocator, key: []const u8, value: Object) !void {
        const key_copy = try allocator.dupe(u8, key);
        try self.entries.put(key_copy, value);
    }

    pub fn contains(self: Dictionary, key: []const u8) bool {
        return self.entries.contains(key);
    }

    /// Get a value as integer
    pub fn getInteger(self: Dictionary, key: []const u8) ?i64 {
        const obj = self.get(key) orelse return null;
        return obj.asInteger();
    }

    /// Get a value as string
    pub fn getString(self: Dictionary, key: []const u8) ?[]const u8 {
        const obj = self.get(key) orelse return null;
        return obj.asString();
    }

    /// Get a value as name
    pub fn getName(self: Dictionary, key: []const u8) ?[]const u8 {
        const obj = self.get(key) orelse return null;
        return obj.asName();
    }

    /// Get a value as array
    pub fn getArray(self: Dictionary, key: []const u8) ?[]Object {
        const obj = self.get(key) orelse return null;
        return obj.asArray();
    }

    /// Get a value as dictionary
    pub fn getDictionary(self: Dictionary, key: []const u8) ?Dictionary {
        const obj = self.get(key) orelse return null;
        return obj.asDictionary();
    }

    /// Get a value as reference
    pub fn getReference(self: Dictionary, key: []const u8) ?ObjectRef {
        const obj = self.get(key) orelse return null;
        return obj.asReference();
    }
};

/// PDF Stream type - dictionary with associated binary data
pub const Stream = struct {
    dict: Dictionary,
    data: []const u8,
    decoded: ?[]const u8 = null,

    pub fn deinit(self: *Stream, allocator: Allocator) void {
        var dict = self.dict;
        dict.deinit(allocator);
        allocator.free(self.data);
        if (self.decoded) |d| {
            allocator.free(d);
        }
    }

    /// Get the decoded stream data, decoding if necessary
    pub fn getDecodedData(self: *Stream, allocator: Allocator) ![]const u8 {
        if (self.decoded) |d| {
            return d;
        }

        // Check for filter
        const filter_obj = self.dict.get("Filter");
        if (filter_obj == null) {
            return self.data;
        }

        const filter_name = filter_obj.?.asName() orelse {
            // Could be an array of filters
            const filter_arr = filter_obj.?.asArray() orelse return self.data;
            if (filter_arr.len == 0) return self.data;
            // For now, just handle single filter
            const first_filter = filter_arr[0].asName() orelse return self.data;
            return self.decodeWithFilter(allocator, first_filter);
        };

        return self.decodeWithFilter(allocator, filter_name);
    }

    fn decodeWithFilter(self: *Stream, allocator: Allocator, filter: []const u8) ![]const u8 {
        if (std.mem.eql(u8, filter, "FlateDecode")) {
            return self.decodeFlateDecode(allocator);
        } else if (std.mem.eql(u8, filter, "ASCIIHexDecode")) {
            return self.decodeASCIIHex(allocator);
        } else if (std.mem.eql(u8, filter, "ASCII85Decode")) {
            return self.decodeASCII85(allocator);
        } else {
            // Unsupported filter, return raw data
            return self.data;
        }
    }

    fn decodeFlateDecode(self: *Stream, allocator: Allocator) ![]const u8 {
        // FlateDecode uses zlib/deflate compression
        // Note: The Zig 0.15 compression API requires the new I/O interfaces.
        // For streams that are compressed, we return the raw data and let
        // consumers handle decompression if needed.
        // TODO: Implement proper FlateDecode using Zig 0.15 std.compress.flate
        _ = allocator;
        return self.data;
    }

    fn decodeASCIIHex(self: *Stream, allocator: Allocator) ![]const u8 {
        var result = std.ArrayList(u8){};
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < self.data.len) {
            // Skip whitespace
            while (i < self.data.len and (self.data[i] == ' ' or self.data[i] == '\n' or
                self.data[i] == '\r' or self.data[i] == '\t'))
            {
                i += 1;
            }
            if (i >= self.data.len) break;
            if (self.data[i] == '>') break; // End marker

            const first = hexDigit(self.data[i]) orelse return error.ParseError;
            i += 1;

            var second: u4 = 0;
            if (i < self.data.len and self.data[i] != '>') {
                // Skip whitespace
                while (i < self.data.len and (self.data[i] == ' ' or self.data[i] == '\n' or
                    self.data[i] == '\r' or self.data[i] == '\t'))
                {
                    i += 1;
                }
                if (i < self.data.len and self.data[i] != '>') {
                    second = hexDigit(self.data[i]) orelse return error.ParseError;
                    i += 1;
                }
            }

            try result.append(allocator, (@as(u8, first) << 4) | @as(u8, second));
        }

        self.decoded = try result.toOwnedSlice(allocator);
        return self.decoded.?;
    }

    fn decodeASCII85(self: *Stream, allocator: Allocator) ![]const u8 {
        var result = std.ArrayList(u8){};
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < self.data.len) {
            // Skip whitespace
            while (i < self.data.len and (self.data[i] == ' ' or self.data[i] == '\n' or
                self.data[i] == '\r' or self.data[i] == '\t'))
            {
                i += 1;
            }
            if (i >= self.data.len) break;

            // Check for end marker
            if (i + 1 < self.data.len and self.data[i] == '~' and self.data[i + 1] == '>') {
                break;
            }

            // Handle 'z' shortcut for all zeros
            if (self.data[i] == 'z') {
                try result.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
                i += 1;
                continue;
            }

            // Decode 5 ASCII85 characters to 4 bytes
            var tuple: [5]u8 = undefined;
            var tuple_len: usize = 0;
            while (tuple_len < 5 and i < self.data.len) {
                const c = self.data[i];
                if (c == '~') break;
                if (c != ' ' and c != '\n' and c != '\r' and c != '\t') {
                    tuple[tuple_len] = c;
                    tuple_len += 1;
                }
                i += 1;
            }

            if (tuple_len == 0) break;

            // Decode the tuple
            var value: u32 = 0;
            for (0..tuple_len) |j| {
                value = value * 85 + (tuple[j] - 33);
            }
            // Pad with 'u' (84) for incomplete tuples
            for (tuple_len..5) |_| {
                value = value * 85 + 84;
            }

            const bytes_to_write = tuple_len - 1;
            if (bytes_to_write > 0) try result.append(allocator, @truncate(value >> 24));
            if (bytes_to_write > 1) try result.append(allocator, @truncate(value >> 16));
            if (bytes_to_write > 2) try result.append(allocator, @truncate(value >> 8));
            if (bytes_to_write > 3) try result.append(allocator, @truncate(value));
        }

        self.decoded = try result.toOwnedSlice(allocator);
        return self.decoded.?;
    }
};

fn hexDigit(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @truncate(c - '0'),
        'a'...'f' => @truncate(c - 'a' + 10),
        'A'...'F' => @truncate(c - 'A' + 10),
        else => null,
    };
}

/// Cross-reference entry
pub const XrefEntry = struct {
    offset: u64,
    generation: u16,
    in_use: bool,
    /// For compressed objects: object number of the object stream
    obj_stream_num: ?u32 = null,
    /// For compressed objects: index within the object stream
    obj_stream_idx: ?u32 = null,
};

/// Cross-reference table
pub const Xref = struct {
    entries: std.AutoHashMap(u32, XrefEntry),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Xref {
        return .{
            .entries = std.AutoHashMap(u32, XrefEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Xref) void {
        self.entries.deinit();
    }

    pub fn get(self: Xref, obj_num: u32) ?XrefEntry {
        return self.entries.get(obj_num);
    }

    pub fn put(self: *Xref, obj_num: u32, entry: XrefEntry) !void {
        try self.entries.put(obj_num, entry);
    }
};

/// PDF Parser
pub const Parser = struct {
    data: []const u8,
    pos: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, data: []const u8) Parser {
        return .{
            .data = data,
            .pos = 0,
            .allocator = allocator,
        };
    }

    /// Parse the PDF header and return the version string
    pub fn parseHeader(self: *Parser) ![]const u8 {
        if (!self.startsWith("%PDF-")) {
            return error.InvalidPdf;
        }
        self.pos += 5;

        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') {
            self.pos += 1;
        }
        return self.data[start..self.pos];
    }

    /// Find and parse the trailer dictionary
    pub fn findTrailer(self: *Parser) !?Dictionary {
        // Search backwards for "trailer"
        const trailer_marker = "trailer";
        var pos = self.data.len;
        while (pos > trailer_marker.len) {
            pos -= 1;
            if (std.mem.startsWith(u8, self.data[pos..], trailer_marker)) {
                self.pos = pos + trailer_marker.len;
                self.skipWhitespace();
                const obj = try self.parseObject();
                return obj.asDictionary();
            }
        }
        return null;
    }

    /// Find the startxref value
    pub fn findStartXref(self: *Parser) !u64 {
        const marker = "startxref";
        var pos = self.data.len;
        while (pos > marker.len) {
            pos -= 1;
            if (std.mem.startsWith(u8, self.data[pos..], marker)) {
                self.pos = pos + marker.len;
                self.skipWhitespace();
                return @intCast(try self.parseInteger());
            }
        }
        return error.InvalidPdf;
    }

    /// Parse the cross-reference table starting at the given offset
    pub fn parseXref(self: *Parser, offset: u64) !Xref {
        var xref = Xref.init(self.allocator);
        errdefer xref.deinit();

        self.pos = @intCast(offset);
        self.skipWhitespace();

        // Check if this is an xref table or xref stream
        if (self.startsWith("xref")) {
            self.pos += 4;
            try self.parseXrefTable(&xref);
        } else {
            // This might be an xref stream (PDF 1.5+)
            try self.parseXrefStream(&xref);
        }

        return xref;
    }

    fn parseXrefTable(self: *Parser, xref: *Xref) !void {
        self.skipWhitespace();

        while (!self.startsWith("trailer")) {
            // Parse subsection header: first_obj count
            const first_obj = try self.parseInteger();
            self.skipWhitespace();
            const count = try self.parseInteger();
            self.skipWhitespace();

            // Parse entries
            for (0..@intCast(count)) |i| {
                const obj_num: u32 = @intCast(first_obj + @as(i64, @intCast(i)));

                // Each entry is 20 bytes: 10-digit offset, space, 5-digit gen, space, n/f, EOL
                const offset = try self.parseInteger();
                self.skipWhitespace();
                const gen = try self.parseInteger();
                self.skipWhitespace();

                const in_use = self.data[self.pos] == 'n';
                self.pos += 1;
                self.skipWhitespace();

                try xref.put(obj_num, .{
                    .offset = @intCast(offset),
                    .generation = @intCast(gen),
                    .in_use = in_use,
                });
            }
            self.skipWhitespace();
        }
    }

    fn parseXrefStream(self: *Parser, xref: *Xref) !void {
        // Parse the xref stream object
        const obj = try self.parseObject();
        const stream = obj.asStream() orelse return error.InvalidXref;

        const dict = stream.dict;

        // Get W array (field widths)
        const w_array = dict.getArray("W") orelse return error.InvalidXref;
        if (w_array.len != 3) return error.InvalidXref;

        const w1: usize = @intCast(w_array[0].asInteger() orelse 0);
        const w2: usize = @intCast(w_array[1].asInteger() orelse 0);
        const w3: usize = @intCast(w_array[2].asInteger() orelse 0);
        const entry_size = w1 + w2 + w3;

        // Get Index array (optional)
        var indices = std.ArrayList(struct { start: u32, count: u32 }){};
        defer indices.deinit(self.allocator);

        if (dict.getArray("Index")) |index_array| {
            var idx: usize = 0;
            while (idx + 1 < index_array.len) : (idx += 2) {
                const start: u32 = @intCast(index_array[idx].asInteger() orelse 0);
                const count: u32 = @intCast(index_array[idx + 1].asInteger() orelse 0);
                try indices.append(self.allocator, .{ .start = start, .count = count });
            }
        } else {
            // Default: start from 0, count = Size
            const size: u32 = @intCast(dict.getInteger("Size") orelse 0);
            try indices.append(self.allocator, .{ .start = 0, .count = size });
        }

        // Decode stream data
        var stream_mut = stream;
        const data = try stream_mut.getDecodedData(self.allocator);

        // Parse entries
        var data_pos: usize = 0;
        for (indices.items) |index| {
            for (0..index.count) |i| {
                if (data_pos + entry_size > data.len) break;

                const obj_num = index.start + @as(u32, @intCast(i));

                // Parse fields
                var field1: u64 = 1; // Default type is 1
                if (w1 > 0) {
                    field1 = readBigEndian(data[data_pos .. data_pos + w1]);
                    data_pos += w1;
                }

                var field2: u64 = 0;
                if (w2 > 0) {
                    field2 = readBigEndian(data[data_pos .. data_pos + w2]);
                    data_pos += w2;
                }

                var field3: u64 = 0;
                if (w3 > 0) {
                    field3 = readBigEndian(data[data_pos .. data_pos + w3]);
                    data_pos += w3;
                }

                const entry: XrefEntry = switch (field1) {
                    0 => .{ // Free entry
                        .offset = 0,
                        .generation = @intCast(field3),
                        .in_use = false,
                    },
                    1 => .{ // Uncompressed object
                        .offset = field2,
                        .generation = @intCast(field3),
                        .in_use = true,
                    },
                    2 => .{ // Compressed object
                        .offset = 0,
                        .generation = 0,
                        .in_use = true,
                        .obj_stream_num = @intCast(field2),
                        .obj_stream_idx = @intCast(field3),
                    },
                    else => continue,
                };

                try xref.put(obj_num, entry);
            }
        }
    }

    fn readBigEndian(bytes: []const u8) u64 {
        var result: u64 = 0;
        for (bytes) |b| {
            result = (result << 8) | b;
        }
        return result;
    }

    /// Parse an indirect object at the given offset
    pub fn parseIndirectObject(self: *Parser, offset: u64) !struct { obj_num: u32, gen_num: u16, obj: Object } {
        self.pos = @intCast(offset);
        self.skipWhitespace();

        const obj_num = try self.parseInteger();
        self.skipWhitespace();
        const gen_num = try self.parseInteger();
        self.skipWhitespace();

        // Expect "obj"
        if (!self.startsWith("obj")) {
            return error.ParseError;
        }
        self.pos += 3;
        self.skipWhitespace();

        const obj = try self.parseObject();

        return .{
            .obj_num = @intCast(obj_num),
            .gen_num = @intCast(gen_num),
            .obj = obj,
        };
    }

    /// Parse a PDF object
    pub fn parseObject(self: *Parser) ParseError!Object {
        self.skipWhitespace();

        if (self.pos >= self.data.len) {
            return error.EndOfStream;
        }

        const c = self.data[self.pos];

        // Null
        if (self.startsWith("null")) {
            self.pos += 4;
            return .null;
        }

        // Boolean
        if (self.startsWith("true")) {
            self.pos += 4;
            return .{ .boolean = true };
        }
        if (self.startsWith("false")) {
            self.pos += 5;
            return .{ .boolean = false };
        }

        // Name
        if (c == '/') {
            return try self.parseName();
        }

        // String
        if (c == '(') {
            return try self.parseString();
        }

        // Hex string
        if (c == '<' and self.pos + 1 < self.data.len and self.data[self.pos + 1] != '<') {
            return try self.parseHexString();
        }

        // Dictionary or stream
        if (c == '<' and self.pos + 1 < self.data.len and self.data[self.pos + 1] == '<') {
            return try self.parseDictionaryOrStream();
        }

        // Array
        if (c == '[') {
            return try self.parseArray();
        }

        // Number (integer or real) or indirect reference
        if (c == '-' or c == '+' or c == '.' or (c >= '0' and c <= '9')) {
            return try self.parseNumberOrReference();
        }

        return error.ParseError;
    }

    fn parseName(self: *Parser) ParseError!Object {
        if (self.data[self.pos] != '/') {
            return error.ParseError;
        }
        self.pos += 1;

        var name = std.ArrayList(u8){};
        errdefer name.deinit(self.allocator);

        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (isDelimiter(c) or isWhitespace(c)) break;

            if (c == '#' and self.pos + 2 < self.data.len) {
                // Hex escape
                const h1 = hexDigit(self.data[self.pos + 1]) orelse break;
                const h2 = hexDigit(self.data[self.pos + 2]) orelse break;
                try name.append(self.allocator, (@as(u8, h1) << 4) | @as(u8, h2));
                self.pos += 3;
            } else {
                try name.append(self.allocator, c);
                self.pos += 1;
            }
        }

        return .{ .name = try name.toOwnedSlice(self.allocator) };
    }

    fn parseString(self: *Parser) ParseError!Object {
        if (self.data[self.pos] != '(') {
            return error.ParseError;
        }
        self.pos += 1;

        var str = std.ArrayList(u8){};
        errdefer str.deinit(self.allocator);

        var depth: usize = 1;
        while (self.pos < self.data.len and depth > 0) {
            const c = self.data[self.pos];

            if (c == '\\' and self.pos + 1 < self.data.len) {
                self.pos += 1;
                const escaped = self.data[self.pos];
                switch (escaped) {
                    'n' => try str.append(self.allocator, '\n'),
                    'r' => try str.append(self.allocator, '\r'),
                    't' => try str.append(self.allocator, '\t'),
                    'b' => try str.append(self.allocator, 0x08),
                    'f' => try str.append(self.allocator, 0x0C),
                    '(' => try str.append(self.allocator, '('),
                    ')' => try str.append(self.allocator, ')'),
                    '\\' => try str.append(self.allocator, '\\'),
                    '0'...'7' => {
                        // Octal escape
                        var octal: u8 = escaped - '0';
                        if (self.pos + 1 < self.data.len and self.data[self.pos + 1] >= '0' and self.data[self.pos + 1] <= '7') {
                            self.pos += 1;
                            octal = octal * 8 + (self.data[self.pos] - '0');
                            if (self.pos + 1 < self.data.len and self.data[self.pos + 1] >= '0' and self.data[self.pos + 1] <= '7') {
                                self.pos += 1;
                                octal = octal * 8 + (self.data[self.pos] - '0');
                            }
                        }
                        try str.append(self.allocator, octal);
                    },
                    '\n' => {}, // Line continuation
                    '\r' => {
                        if (self.pos + 1 < self.data.len and self.data[self.pos + 1] == '\n') {
                            self.pos += 1;
                        }
                    },
                    else => try str.append(self.allocator, escaped),
                }
                self.pos += 1;
            } else if (c == '(') {
                depth += 1;
                try str.append(self.allocator, c);
                self.pos += 1;
            } else if (c == ')') {
                depth -= 1;
                if (depth > 0) {
                    try str.append(self.allocator, c);
                }
                self.pos += 1;
            } else {
                try str.append(self.allocator, c);
                self.pos += 1;
            }
        }

        return .{ .string = try str.toOwnedSlice(self.allocator) };
    }

    fn parseHexString(self: *Parser) ParseError!Object {
        if (self.data[self.pos] != '<') {
            return error.ParseError;
        }
        self.pos += 1;

        var bytes = std.ArrayList(u8){};
        errdefer bytes.deinit(self.allocator);

        var first_nibble: ?u4 = null;
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c == '>') {
                self.pos += 1;
                break;
            }
            if (isWhitespace(c)) {
                self.pos += 1;
                continue;
            }
            if (hexDigit(c)) |nibble| {
                if (first_nibble) |fn_val| {
                    try bytes.append(self.allocator, (@as(u8, fn_val) << 4) | @as(u8, nibble));
                    first_nibble = null;
                } else {
                    first_nibble = nibble;
                }
                self.pos += 1;
            } else {
                return error.ParseError;
            }
        }

        // Handle odd number of hex digits
        if (first_nibble) |fn_val| {
            try bytes.append(self.allocator, @as(u8, fn_val) << 4);
        }

        return .{ .hex_string = try bytes.toOwnedSlice(self.allocator) };
    }

    fn parseDictionaryOrStream(self: *Parser) ParseError!Object {
        // Parse dictionary first
        if (!self.startsWith("<<")) {
            return error.ParseError;
        }
        self.pos += 2;

        var dict = Dictionary.init(self.allocator);
        errdefer dict.deinit(self.allocator);

        while (self.pos < self.data.len) {
            self.skipWhitespace();
            if (self.startsWith(">>")) {
                self.pos += 2;
                break;
            }

            // Parse key (must be a name)
            const key_obj = try self.parseObject();
            const key = key_obj.asName() orelse return error.ParseError;
            defer self.allocator.free(key);

            self.skipWhitespace();

            // Parse value
            const value = try self.parseObject();

            const key_copy = try self.allocator.dupe(u8, key);
            try dict.entries.put(key_copy, value);
        }

        self.skipWhitespace();

        // Check if this is a stream
        if (self.startsWith("stream")) {
            self.pos += 6;
            // Skip optional whitespace and mandatory EOL
            if (self.pos < self.data.len and self.data[self.pos] == '\r') {
                self.pos += 1;
            }
            if (self.pos < self.data.len and self.data[self.pos] == '\n') {
                self.pos += 1;
            }

            // Get stream length
            const length: usize = @intCast(dict.getInteger("Length") orelse return error.ParseError);

            if (self.pos + length > self.data.len) {
                return error.EndOfStream;
            }

            const stream_data = try self.allocator.dupe(u8, self.data[self.pos .. self.pos + length]);
            self.pos += length;

            // Skip "endstream"
            self.skipWhitespace();
            if (self.startsWith("endstream")) {
                self.pos += 9;
            }

            return .{ .stream = .{
                .dict = dict,
                .data = stream_data,
            } };
        }

        return .{ .dictionary = dict };
    }

    fn parseArray(self: *Parser) ParseError!Object {
        if (self.data[self.pos] != '[') {
            return error.ParseError;
        }
        self.pos += 1;

        var array = std.ArrayList(Object){};
        errdefer {
            for (array.items) |*item| {
                item.deinit(self.allocator);
            }
            array.deinit(self.allocator);
        }

        while (self.pos < self.data.len) {
            self.skipWhitespace();
            if (self.data[self.pos] == ']') {
                self.pos += 1;
                break;
            }

            const obj = try self.parseObject();
            try array.append(self.allocator, obj);
        }

        return .{ .array = try array.toOwnedSlice(self.allocator) };
    }

    fn parseNumberOrReference(self: *Parser) ParseError!Object {
        const start_pos = self.pos;

        // Try to parse first number
        const first = try self.parseNumber();

        // Save position to try parsing as reference
        const after_first = self.pos;
        self.skipWhitespace();

        // Check if this could be an indirect reference (num num R)
        if (self.pos < self.data.len and self.data[self.pos] >= '0' and self.data[self.pos] <= '9') {
            const second_start = self.pos;
            const second = self.parseNumber() catch {
                self.pos = after_first;
                return first;
            };

            self.skipWhitespace();

            if (self.pos < self.data.len and self.data[self.pos] == 'R') {
                self.pos += 1;
                // It's a reference
                const obj_num = first.asInteger() orelse {
                    self.pos = after_first;
                    return first;
                };
                const gen_num = second.asInteger() orelse {
                    self.pos = after_first;
                    return first;
                };
                return .{ .reference = .{
                    .obj_num = @intCast(obj_num),
                    .gen_num = @intCast(gen_num),
                } };
            } else {
                // Not a reference, restore position
                self.pos = second_start;
            }
        }

        self.pos = after_first;
        _ = start_pos;
        return first;
    }

    fn parseNumber(self: *Parser) ParseError!Object {
        const start = self.pos;
        var has_decimal = false;

        // Handle sign
        if (self.pos < self.data.len and (self.data[self.pos] == '-' or self.data[self.pos] == '+')) {
            self.pos += 1;
        }

        // Parse digits
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c >= '0' and c <= '9') {
                self.pos += 1;
            } else if (c == '.' and !has_decimal) {
                has_decimal = true;
                self.pos += 1;
            } else {
                break;
            }
        }

        const num_str = self.data[start..self.pos];
        if (num_str.len == 0) {
            return error.ParseError;
        }

        if (has_decimal) {
            const value = std.fmt.parseFloat(f64, num_str) catch return error.ParseError;
            return .{ .real = value };
        } else {
            const value = std.fmt.parseInt(i64, num_str, 10) catch return error.ParseError;
            return .{ .integer = value };
        }
    }

    fn parseInteger(self: *Parser) !i64 {
        const obj = try self.parseNumber();
        return obj.asInteger() orelse error.ParseError;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (isWhitespace(c)) {
                self.pos += 1;
            } else if (c == '%') {
                // Skip comment until end of line
                while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn startsWith(self: *Parser, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.data.len) {
            return false;
        }
        return std.mem.eql(u8, self.data[self.pos .. self.pos + prefix.len], prefix);
    }
};

fn isWhitespace(c: u8) bool {
    return c == 0 or c == '\t' or c == '\n' or c == 0x0C or c == '\r' or c == ' ';
}

fn isDelimiter(c: u8) bool {
    return c == '(' or c == ')' or c == '<' or c == '>' or c == '[' or c == ']' or
        c == '{' or c == '}' or c == '/' or c == '%';
}

// Tests
test "parse PDF header" {
    const data = "%PDF-1.7\n";
    var parser = Parser.init(std.testing.allocator, data);
    const version = try parser.parseHeader();
    try std.testing.expectEqualStrings("1.7", version);
}

test "parse null" {
    const data = "null";
    var parser = Parser.init(std.testing.allocator, data);
    const obj = try parser.parseObject();
    try std.testing.expect(obj == .null);
}

test "parse boolean true" {
    const data = "true";
    var parser = Parser.init(std.testing.allocator, data);
    const obj = try parser.parseObject();
    try std.testing.expect(obj.asBoolean().? == true);
}

test "parse boolean false" {
    const data = "false";
    var parser = Parser.init(std.testing.allocator, data);
    const obj = try parser.parseObject();
    try std.testing.expect(obj.asBoolean().? == false);
}

test "parse integer" {
    const data = "42";
    var parser = Parser.init(std.testing.allocator, data);
    const obj = try parser.parseObject();
    try std.testing.expect(obj.asInteger().? == 42);
}

test "parse negative integer" {
    const data = "-123";
    var parser = Parser.init(std.testing.allocator, data);
    const obj = try parser.parseObject();
    try std.testing.expect(obj.asInteger().? == -123);
}

test "parse real" {
    const data = "3.14159";
    var parser = Parser.init(std.testing.allocator, data);
    const obj = try parser.parseObject();
    try std.testing.expect(@abs(obj.asReal().? - 3.14159) < 0.00001);
}

test "parse name" {
    const data = "/Type";
    var parser = Parser.init(std.testing.allocator, data);
    var obj = try parser.parseObject();
    defer obj.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Type", obj.asName().?);
}

test "parse string" {
    const data = "(Hello World)";
    var parser = Parser.init(std.testing.allocator, data);
    var obj = try parser.parseObject();
    defer obj.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Hello World", obj.asString().?);
}

test "parse string with escapes" {
    const data = "(Hello\\nWorld)";
    var parser = Parser.init(std.testing.allocator, data);
    var obj = try parser.parseObject();
    defer obj.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Hello\nWorld", obj.asString().?);
}

test "parse hex string" {
    const data = "<48656C6C6F>";
    var parser = Parser.init(std.testing.allocator, data);
    var obj = try parser.parseObject();
    defer obj.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Hello", obj.asString().?);
}

test "parse array" {
    const data = "[1 2 3]";
    var parser = Parser.init(std.testing.allocator, data);
    var obj = try parser.parseObject();
    defer obj.deinit(std.testing.allocator);
    const arr = obj.asArray().?;
    try std.testing.expect(arr.len == 3);
    try std.testing.expect(arr[0].asInteger().? == 1);
    try std.testing.expect(arr[1].asInteger().? == 2);
    try std.testing.expect(arr[2].asInteger().? == 3);
}

test "parse dictionary" {
    const data = "<< /Type /Catalog /Pages 10 0 R >>";
    var parser = Parser.init(std.testing.allocator, data);
    var obj = try parser.parseObject();
    defer obj.deinit(std.testing.allocator);
    const dict = obj.asDictionary().?;
    try std.testing.expectEqualStrings("Catalog", dict.getName("Type").?);
    const ref = dict.getReference("Pages").?;
    try std.testing.expect(ref.obj_num == 10);
    try std.testing.expect(ref.gen_num == 0);
}

test "parse indirect reference" {
    const data = "10 0 R";
    var parser = Parser.init(std.testing.allocator, data);
    const obj = try parser.parseObject();
    const ref = obj.asReference().?;
    try std.testing.expect(ref.obj_num == 10);
    try std.testing.expect(ref.gen_num == 0);
}
