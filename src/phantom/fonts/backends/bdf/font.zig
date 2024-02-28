const std = @import("std");
const Allocator = std.mem.Allocator;
const phantom = @import("phantom");
const vizops = @import("vizops");
const Self = @This();

const Mode = enum {
    start,
    head,
    properties,
    chars,
};

const Keyword = enum {
    COMMENT,
    CONTENTVERSION,
    FONT,
    SIZE,
    FONTBOUNDINGBOX,
    METRICSSET,
    STARTPROPERTIES,
    ENDPROPERTIES,
    CHARS,
    STARTCHAR,
    ENCODING,
    SWIDTH,
    DWIDTH,
    SWIDTH1,
    DWIDTH1,
    VVECTOR,
    BBX,
    BITMAP,
    ENDCHAR,
    ENDFONT,
};

base: phantom.fonts.Font,
allocator: Allocator,
size: vizops.vector.UsizeVector2,
depth: u8,
boundingBox: struct {
    vizops.vector.Uint8Vector2,
    vizops.vector.Int8Vector2,
},
glyphs: std.AutoHashMapUnmanaged(u21, phantom.fonts.Font.Glyph),

pub fn create(alloc: Allocator, reader: anytype, options: phantom.fonts.Format.LoadOptions) !*phantom.fonts.Font {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    self.* = .{
        .base = .{
            .vtable = &.{
                .lookupGlyph = lookupGlyph,
                .getSize = getSize,
                .deinit = deinit,
            },
            .ptr = self,
        },
        .allocator = alloc,
        .size = vizops.vector.UsizeVector2.zero(),
        .depth = 0,
        .boundingBox = .{
            vizops.vector.Uint8Vector2.zero(),
            vizops.vector.Int8Vector2.zero(),
        },
        .glyphs = .{},
    };

    var mode = Mode.start;
    var propertycount: usize = 0;

    while (try readLine(alloc, reader)) |line| {
        defer alloc.free(line);

        switch (mode) {
            .start => {
                if (std.mem.eql(u8, line, "STARTFONT 2.1")) {
                    mode = .head;
                } else {
                    return error.InvalidMagic;
                }
            },
            .head => {
                var iter = std.mem.splitScalar(u8, line, ' ');
                const word = iter.next().?;

                switch (std.meta.stringToEnum(Keyword, word) orelse return error.InvalidKeyword) {
                    .SIZE => {
                        const size = readInfo(line, .SIZE, .{ u8, u8, u8 });
                        self.size.value[0] = size[0];
                        self.size.value[1] = size[1];
                        self.depth = size[2];
                    },
                    .FONTBOUNDINGBOX => {
                        const bbox = readInfo(line, .FONTBOUNDINGBOX, .{ u8, u8, i8, i8 });
                        self.boundingBox[0].value[0] = bbox[0];
                        self.boundingBox[0].value[1] = bbox[1];
                        self.boundingBox[1].value[0] = bbox[2];
                        self.boundingBox[1].value[1] = bbox[3];
                    },
                    .STARTPROPERTIES => {
                        const count = (readInfo(line, .STARTPROPERTIES, .{usize}))[0];
                        propertycount = count;
                        mode = .properties;
                    },
                    else => continue,
                }
            },
            .properties => {
                if (propertycount == 0) {
                    _ = readInfo(line, .ENDPROPERTIES, .{});
                    mode = .chars;
                    continue;
                }

                propertycount -= 1;
            },
            .chars => {
                var count = readInfo(line, .CHARS, .{usize})[0];

                const colorLen = @divExact(options.colorFormat.width(), 8);

                const backgroundBuffer = try alloc.alloc(u8, colorLen);
                defer alloc.free(backgroundBuffer);
                try vizops.color.writeAnyBuffer(options.colorFormat, backgroundBuffer, options.backgroundColor);

                const foregroundBuffer = try alloc.alloc(u8, colorLen);
                defer alloc.free(foregroundBuffer);
                try vizops.color.writeAnyBuffer(options.colorFormat, foregroundBuffer, options.foregroundColor);

                while (count > 0) {
                    {
                        const tmp = try readLine(alloc, reader) orelse return error.EndOfStream;
                        defer alloc.free(tmp);
                        _ = readInfoS(tmp, .STARTCHAR);
                    }

                    const encoding: u21 = blk: {
                        const tmp = try readLine(alloc, reader) orelse return error.EndOfStream;
                        defer alloc.free(tmp);
                        break :blk readInfo(tmp, .ENCODING, .{u21})[0];
                    };

                    {
                        const tmp = try readLine(alloc, reader) orelse return error.EndOfStream;
                        defer alloc.free(tmp);
                        _ = readInfo(tmp, .SWIDTH, .{ u16, u16 });
                    }

                    const dwidth: struct { u16, u16 } = blk: {
                        const tmp = try readLine(alloc, reader) orelse return error.EndOfStream;
                        defer alloc.free(tmp);
                        break :blk readInfo(tmp, .DWIDTH, .{ u16, u16 });
                    };

                    const bbox: struct { u8, u8, i8, i8 } = blk: {
                        const tmp = try readLine(alloc, reader) orelse return error.EndOfStream;
                        defer alloc.free(tmp);
                        break :blk readInfo(tmp, .BBX, .{ u8, u8, i8, i8 });
                    };

                    {
                        const tmp = try readLine(alloc, reader) orelse return error.EndOfStream;
                        defer alloc.free(tmp);
                        _ = readInfo(tmp, .BITMAP, .{});
                    }

                    var fb = try phantom.painting.fb.AllocatedFrameBuffer.create(alloc, .{
                        .res = .{ .value = .{ bbox[0], bbox[1] } },
                        .colorspace = options.colorspace,
                        .colorFormat = options.colorFormat,
                    });
                    errdefer fb.deinit();

                    var y: usize = 0;
                    while (true) {
                        const line2 = try readLine(alloc, reader) orelse return error.EndOfStream;
                        defer alloc.free(line2);

                        if (std.mem.eql(u8, line2, "ENDCHAR")) {
                            count -= 1;
                            break;
                        }

                        var masks: [1]u8 = undefined;
                        for (0..masks.len) |k| {
                            masks[k] = std.fmt.parseInt(u8, line2[k * 2 ..][0..2], 16) catch unreachable;
                            masks[k] = @bitReverse(masks[k]);
                        }

                        var set = std.bit_set.ArrayBitSet(u8, 8 * masks.len){ .masks = masks };
                        for (0..8) |x| {
                            const stride = colorLen * bbox[0];
                            const i = (y * stride) + (x * colorLen);
                            try fb.write(i, if (set.isSet(x)) foregroundBuffer else backgroundBuffer);
                        }

                        y += 1;
                    }

                    try self.glyphs.put(alloc, encoding, .{
                        .index = self.glyphs.count(),
                        .fb = fb,
                        .size = .{ .value = .{ bbox[0], bbox[1] } },
                        .bearing = .{ .value = .{ bbox[2], @as(i8, @intCast(bbox[1])) + bbox[3] } },
                        .advance = .{ .value = .{ @intCast(dwidth[0]), @intCast(dwidth[1]) } },
                    });
                }

                {
                    const tmp = try readLine(alloc, reader) orelse return error.EndOfStream;
                    defer alloc.free(tmp);
                    _ = readInfo(tmp, .ENDFONT, .{});
                }
            },
        }
    }

    return &self.base;
}

fn lookupGlyph(ctx: *anyopaque, codepoint: u21) anyerror!phantom.fonts.Font.Glyph {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (self.glyphs.get(codepoint)) |glyph| {
        return glyph;
    }
    return error.GlyphNotFound;
}

fn getSize(ctx: *anyopaque) vizops.vector.UsizeVector2 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.size;
}

fn deinit(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    var iter = self.glyphs.valueIterator();
    while (iter.next()) |glyph| {
        glyph.fb.deinit();
    }

    self.glyphs.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn readInfo(line: []const u8, k: Keyword, comptime ts: anytype) std.meta.Tuple(&ts) {
    const types: [ts.len]type = ts;
    var result: std.meta.Tuple(&types) = undefined;
    var iter = std.mem.splitScalar(u8, line, ' ');
    const word = std.meta.stringToEnum(Keyword, iter.next().?).?;
    std.debug.assert(word == k);
    inline for (types, 0..) |T, i| {
        result[i] = std.fmt.parseInt(T, iter.next().?, 10) catch unreachable;
    }
    std.debug.assert(iter.next() == null);
    return result;
}

fn readLine(alloc: Allocator, reader: anytype) !?[]const u8 {
    var line = std.ArrayList(u8).init(alloc);
    defer line.deinit();

    reader.streamUntilDelimiter(line.writer(), '\n', null) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };

    return try line.toOwnedSlice();
}

fn readInfoS(line: []const u8, k: Keyword) []const u8 {
    var iter = std.mem.splitScalar(u8, line, ' ');
    const word = std.meta.stringToEnum(Keyword, iter.next().?).?;
    std.debug.assert(word == k);
    return iter.rest();
}
