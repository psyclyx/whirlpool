//! Lua standard-library sources embedded for sandboxed retained programs.

pub const workspace = @embedFile("whirlpool/workspace.lua");
pub const angled = @embedFile("whirlpool/angled.lua");
pub const graph = @embedFile("whirlpool/graph.lua");
pub const theme = @embedFile("whirlpool/theme.lua");
pub const status = @embedFile("whirlpool/status.lua");
pub const shell = @embedFile("whirlpool/shell.lua");
pub const decorator = @embedFile("whirlpool/decorator.lua");
