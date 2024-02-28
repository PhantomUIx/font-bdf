const std = @import("std");
const Allocator = std.mem.Allocator;
const phantom = @import("phantom");
const hasFileSystem = @hasDecl(std.os.system, "fd_t");
const Font = @import("bdf/font.zig");
const Self = @This();

base: phantom.fonts.Format,
allocator: Allocator,

pub fn create(alloc: Allocator) Allocator.Error!*phantom.fonts.Format {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    self.* = .{
        .base = .{
            .ptr = self,
            .vtable = &(comptime blk: {
                var vtable: phantom.fonts.Format.VTable = .{
                    .loadBuffer = loadBuffer,
                    .deinit = deinit,
                };

                if (hasFileSystem) {
                    vtable.loadFile = loadFile;
                }

                break :blk vtable;
            }),
        },
        .allocator = alloc,
    };

    return &self.base;
}

fn loadBuffer(ctx: *anyopaque, buff: []const u8, options: phantom.fonts.Format.LoadOptions) anyerror!*phantom.fonts.Font {
    const self: *Self = @ptrCast(@alignCast(ctx));

    var stream = std.io.fixedBufferStream(buff);
    return try Font.create(self.allocator, stream.reader(), options);
}

fn deinit(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.allocator.destroy(self);
}

fn loadFile(ctx: *anyopaque, file: std.fs.File, options: phantom.fonts.Format.LoadOptions) anyerror!*phantom.fonts.Font {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return try Font.create(self.allocator, file.reader(), options);
}
