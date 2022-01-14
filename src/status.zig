// Status management.
//
// The update status is stored in different ways, depending on the
// whether the flash device has "small" or "medium" writes (1-16
// bytes, typically), or "large" writes, typically 512 bytes.  The
// large write devices generally have similarly sized erases.

const config = @import("config.zig");

usingnamespace switch (config.status) {
    .Paged => @import("status/paged.zig"),
    .InPlace => @import("status/inplace.zig"),
};

test {
    _ = @import("status/paged.zig");
    _ = @import("status/inplace.zig");
}
