const std = @import("std");
const builtin = @import("builtin");
const phantom = @import("phantom");

const alloc = if (builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;

pub fn main() !void {
    var file = try std.fs.cwd().openFile("example.bdf", .{});
    defer file.close();

    const format = try phantom.fonts.backends.bdf.create(alloc);
    defer format.deinit();

    const font = try format.loadFile(file, .{
        .colorspace = .sRGB,
        .colorFormat = .{ .rgba = @splat(8) },
        .foregroundColor = .{
            .uint8 = .{
                .sRGB = .{
                    .value = .{ 0, 0, 0, 255 },
                },
            },
        },
        .backgroundColor = .{
            .uint8 = .{
                .sRGB = .{
                    .value = @splat(0),
                },
            },
        },
    });
    defer font.deinit();

    const utfView = std.unicode.Utf8View.initComptime("Hello, world!");
    var iter = utfView.iterator();
    while (iter.nextCodepoint()) |codepoint| {
        const glyph = try font.lookupGlyph(codepoint);
        std.debug.print("{}\n", .{glyph});
    }
}
