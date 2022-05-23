//! A "plain" argument parsing library for zig.
//!
//! Parses parses arguments imperatively (not declaratively),
//! allowing it to reduce compile time magic.

const std = @import("std");
const assert = std.debug.assert;

/// A (simple) parser for arguments
///
/// Essentially this is a thin wrapper over a slice of strings,
/// but with additional utilities to give better error messages.
pub const Parser = struct {
    /// The underlying array of arguments.
    args: []const []const u8,
    /// The current argument index in the overall array
    ///
    /// Please don't touch this
    current_arg_index: usize = 0,
    /// The error information for the last error returned by the parser.
    ///
    /// This provides additional information. beyond 
    error_info: ?CommandParseErrorInfo = null,
    /// DO NOT QUERY DIRECTLY. Use `has_flag_args()`
    finished_flags: bool = false,

    /// Initialize an argument parser.
    ///
    /// This involves zero allocations.
    pub fn init(args: []const []const u8) Parser {
        return Parser {
            .args  = args,
        };
    }

    pub inline fn current_arg(self: *Parser) ?[]const u8 {
        if (self.has_args()) {
            return self.*.args[self.*.current_arg_index];
        } else {
            return null;
        }
    }

    /// Get a slice of the remaining arguments.
    ///
    /// This includes the "current" argument.
    ///
    /// This can be easily used to parse .
    ///
    /// The lifetime of the result matches the original.
    pub fn remaining_args(self: *Parser) []const []const u8 {
        return self.*.args[self.*.current_arg_index..];
    }

    /// Consume the current argument, ignoring its value
    ///
    /// If there are no more arguments (this is out of bounds),
    /// this is safety-checked undefined behavior.
    pub fn consume_arg(self: *Parser) void {
        _ = self.*.next_arg().?;
    }

    /// Get the next argument,
    /// consuming it and returning its value.
    ///
    /// This is most useful for positional arguments (after flag arguments).
    ///
    /// Returns null if there are no more arguments
    pub fn next_arg(self: *Parser) ?[]const u8 {
        if (self.has_args()) {
            const arg = self.*.current_arg().?;
            self.*.current_arg_index += 1;
            return arg;
        } else {
            return null;
        }
    }

    /// Check if the parser has any remaining arguments
    ///
    /// This includes both positional and flag arguments
    pub fn has_args(self: *Parser) bool {
        return self.*.current_arg_index < self.*.args.len;
    }

    /// Check if there are remaining "flag" arguments
    ///
    /// If this is true, there are more option arguments like "--foo" or "-k"
    /// If this is false, all remaining arguments are positional.
    ///
    /// This automatically handles the traditional "--" seperator.
    /// If this is found, it will implciitly consume it
    /// and mark all further arguments as positional.
    pub fn has_flag_args(self: *Parser) bool {
        if (!self.*.has_args()) return false;
        if (self.*.finished_flags) return false;
        const arg = self.*.current_arg().?;
        switch (arg.len) {
            0, 1 => {
                // NOTE: We used to give a warning for '-' as a positional arg.
                // Since neither `cargo pkgid -` or `git rev-parse -` do this
                // I have decided it is not unix-like and have decided
                // to unconditionally accept '-' (and the empty string)
                // as positional arguments
                self.*.finished_flags = true;
            },
            2 => {
                // Three cases:
                // 1. arg == "-k" (short arg)
                // 2. arg == "--" (delimits the positional arguments)
                // 3. arg[0] != '-' (it's positional)
                if (arg[0] == '-') {
                    if (arg[1] == '-') {
                        // case 2 - "--"
                        assert(std.mem.eql(u8, arg, "--"));
                        self.*.consume_arg();
                        self.*.finished_flags = true;
                    } else {
                        // case 1 - short arg
                        self.*.finished_flags = false;
                    }
                } else {
                    // case 3 - positional
                    self.*.finished_flags = true;
                }
            },
            else => {
                if (arg[0] == '-') {
                    assert(!std.mem.eql(u8, arg, "--"));
                    self.*.finished_flags = false;
                } else {
                    // obviously positional
                    self.*.finished_flags = true;
                }
            }
        }
        return !self.*.finished_flags;
    }

    /// Parse a flag argument that matches the specified enum.
    ///
    /// Returns null if there are no more flag arguments (`has_flag_args` returns false)
    /// 
    /// Despite our goal to avoid it, this necessarily involves
    /// comptime magic to detect enum names.
    /// 
    /// By default argument names are inferred from enum names (`.foo_bar` becomes `--foo_bar`)
    /// but this can be overriden with `ArgEnumInfo`.
    /// Not only does this allow overriding the primary name, this 
    ///
    ///
    /// IMPLEMENTATION NOTE:
    /// This avoids a linear search by building
    /// a `std.ComptimeStringMap` of all possible argument names.
    ///
    /// Although this is technically `comptime` magic,
    /// this is strictly an implementation detail and does not affect the API.
    pub fn match_arg_enum(
        self: *Parser,
        comptime ArgId: type,
        comptime explicit_info: []const ArgEnumInfo(ArgId),
    ) CommandParseError!?ArgId {
        comptime {
            switch (@typeInfo(ArgId)) {
                .Enum => {},
                else => @compileError("ArgId must be enum",)
            }
        }
        const num_fields = @typeInfo(ArgId).Enum.fields.len;
        @setEvalBranchQuota(num_fields * 500);
        const infoMap = comptime initInfoMap: {
            var res = std.enums.EnumArray(ArgId, ?ArgEnumInfo(ArgId)).initFill(null);
            inline for (explicit_info) |info| {
                if (res.get(info.arg) != null) {
                    @compileError("Duplicate arg info for " + @tagName(info.arg));
                }
                res.set(info.arg, info);
            }
            inline for (std.meta.tags(ArgId)) |arg| {
                if (res.get(arg) == null) {
                    res.set(arg, ArgEnumInfo(ArgId).infer_default(arg));
                }
            }
            break :initInfoMap &res;
        };
        const total_potential_names = comptime countNames: {
            comptime var count = 0;
            var iter = infoMap.iterator();
            inline while (iter.next()) |entry| {
                const info = entry.value.*.?;
                count += info.count_names();
            }
            break :countNames count;
        };
        const argMap = comptime initArgMap: {
            const KV = struct {
                @"0": []const u8,
                @"1": ArgId,
            };
            var values: [total_potential_names]KV = undefined;
            var iter = infoMap.iterator();
            var i = 0;
            inline while (iter.next()) |entry| {
                const info = entry.value.*.?;
                values[i] = .{ .@"0" = "--" ++ info.name, .@"1" = info.arg };
                i += 1;
                if (info.short) |short_chr| {
                    const short_arg = [2]u8 {'-', short_chr};
                    values[i] = .{ .@"0" = short_arg, .@"1" = info.arg };
                    i += 1;
                }
                inline for (info.aliases) |alias| {
                    values[i] = .{ .@"0" = "--" + alias, .@"1" = info.arg };
                    i += 1;
                }
            }
            assert(i == total_potential_names);
            break :initArgMap std.ComptimeStringMap(ArgId, values);
        };
        if (!self.*.has_flag_args()) return null;
        const arg = self.*.current_arg().?;
        if (argMap.get(arg)) |id| {
            self.*.consume_arg();
            return id;
        } else {
            self.error_info = CommandParseErrorInfo{ .unknown_option = .{
                .arg = arg
            } };
            return CommandParseError.CommandParseError;
        }
    }
};

/// Metadata on an argument enum.
///
/// This can be used to override the inferred name,
/// provide a "short" name, and to provide aliases
pub fn ArgEnumInfo(comptime ArgId: type) type {
    return struct {
        arg: ArgId,
        name: []const u8,
        short: ?u8 = null,
        aliases: []const []const u8 = &.{},

        fn count_names(self: *const @This()) usize {
            var count: usize = 1;
            if (self.*.short != null) count += 1;
            count += self.*.aliases.len;
            return count;
        }

        pub fn infer_default(comptime arg: ArgId) @This() {
            const name = @tagName(arg);
            var normalized_name: [name.len]u8 = undefined;
            for (name) |c, i| {
                const normalized_char = switch (c) {
                    '_' => '-',
                    else => c // TODO: Lowercase?
                };
                normalized_name[i] = normalized_char;
            }
            return .{
                .arg = arg,
                .name = &normalized_name
            };
        }
    };
}


const CommandParseErrorInfo = union(enum) {
    unknown_option: struct {
        arg: []const u8,
    },
};
pub const CommandParseError = error {
    CommandParseError,
};

test "parse implicit enums" {
    var args = Parser.init(&.{"--foo", "--bar", "--potato"});
    var foo = false;
    var bar = false;
    var potato = false;
    // Notice how the enum type is implicit here.
    //
    // can't get much simpler than that
    while (try args.match_arg_enum(
        enum { foo, bar, baz, potato },
        &.{},
    )) |match| {
        switch (match) {
            .foo => foo = true,
            .bar => bar = true,
            .potato => potato = true,
            .baz => unreachable,
        }
    }
    try std.testing.expect(!args.has_args());
    try std.testing.expect(!args.has_flag_args());
    try std.testing.expect(foo);
    try std.testing.expect(bar);
    try std.testing.expect(potato);
}
