pub const OpenMode = enum(u64) {
    read_only = 0x000,
    write_only = 0x001,
    read_write = 0x002,
    create = 0x200,
    truncate = 0x400,
};
