//! Lua standard-library sources embedded for sandboxed retained programs.

pub const workspace = @embedFile("whirlpool/workspace.lua");
pub const theme = @embedFile("whirlpool/theme.lua");
pub const status = @embedFile("whirlpool/status.lua");
pub const icons = @embedFile("whirlpool/icons.lua");
pub const shell = @embedFile("whirlpool/shell.lua");
pub const decorator = @embedFile("whirlpool/decorator.lua");
