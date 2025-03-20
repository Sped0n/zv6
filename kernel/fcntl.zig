pub const OpenMode = struct {
    pub const OpenModeFlag = enum(u64) {
        read_only = 0x000,
        write_only = 0x001,
        read_write = 0x002,
        create = 0x200,
        truncate = 0x400,
        invalid,
    };

    pub fn parse(mode_arg: u64) OpenModeFlag {
        switch (mode_arg) {
            @intFromEnum(OpenModeFlag.read_only) => return OpenModeFlag.read_only,
            @intFromEnum(OpenModeFlag.write_only) => return OpenModeFlag.write_only,
            @intFromEnum(OpenModeFlag.read_write) => return OpenModeFlag.read_write,
            @intFromEnum(OpenModeFlag.create) => return OpenModeFlag.create,
            @intFromEnum(OpenModeFlag.truncate) => return OpenModeFlag.truncate,
            else => return OpenModeFlag.invalid,
        }
    }
};
