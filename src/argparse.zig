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
    /// The start of positional arguments.
    ///
    /// Lazily computed
    positional_start: ?usize = null,

    /// Initialize an argument parser.
    ///
    /// This involves zero allocations.
    pub fn init(args: []const []const u8) Parser {
        return Parser{
            .args = args,
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
        if (self.*.positional_start) |start| {
            assert(start >= self.*.current_arg_index);
            return false;
        }
        if (self.*.check_positional_start(self.current_arg_index)) {
            self.*.current_arg_index = self.*.positional_start.?;
            return false;
        } else {
            return true;
        }
    }

    fn check_positional_start(self: *Parser, start: usize) bool {
        @setCold(true);
        const arg = self.*.args[start];
        switch (arg.len) {
            0, 1 => {
                // NOTE: We used to give a warning for '-' as a positional arg.
                // Since neither `cargo pkgid -` or `git rev-parse -` do this
                // I have decided it is not unix-like and have decided
                // to unconditionally accept '-' (and the empty string)
                // as positional arguments
                self.*.positional_start = start;
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
                        self.*.positional_start = start + 1;
                    } else {
                        // case 1 - short arg
                        self.*.positional_start = null;
                    }
                } else {
                    // case 3 - positional
                    self.*.positional_start = start;
                }
            },
            else => {
                if (arg[0] == '-') {
                    assert(!std.mem.eql(u8, arg, "--"));
                    self.*.positional_start = null;
                } else {
                    // obviously positional
                    self.*.positional_start = start;
                }
            },
        }
        return self.positional_start != null;
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
    pub fn match_flag_enum(
        self: *Parser,
        comptime ArgId: type,
        comptime explicit_info: []const ArgEnumInfo(ArgId),
    ) CommandParseError!?ArgId {
        const num_fields = @typeInfo(ArgId).Enum.fields.len;
        @setEvalBranchQuota(num_fields * 500);
        const infoMap = comptime initInfoMap: {
            var res = std.enums.EnumMap(ArgId, ?[][]const u8).init(.{});
            inline for (explicit_info) |info| {
                if (res.get(info.arg) != null) {
                    @compileError("Duplicate arg info for " + @tagName(info.arg));
                }
                res.set(info.arg, info.matched_names());
            }
            inline for (std.meta.tags(ArgId)) |arg| {
                if (res.get(arg) == null) {
                    res.put(arg, ArgEnumInfo(ArgId).infer_default(arg).matched_names());
                }
            }
            break :initInfoMap &res;
        };
        if (!self.*.has_flag_args()) return null;
        const arg = self.current_arg().?;
        return self.*.expect_arg_value_enum(ArgId, infoMap.*, "flag") catch {
            // Give more specific error
            self.error_info = CommandParseErrorInfo{ .unknown_option = .{ .arg = arg } };
            return CommandParseError.CommandParseError;
        };
    }

    /// Expect an enum argument *value*, returning an error
    /// if nothing matches or if there are not enough arguments.
    ///
    /// Note this is distinct from `match_flag_enum` which matches a flag
    /// against an enum.
    ///
    /// This is distinct, and can be used to parse any type of value
    /// It is also lower level.
    ///
    /// It accepts an (optional) `std.enums.EnumMap` to provide alternative
    /// names/aliases for each enum.
    ///
    /// This is a wrapper around `expect_arg_string`.
    pub fn expect_arg_value_enum(
        self: *Parser,
        comptime T: type,
        comptime explicit_aliases: ?std.enums.EnumMap(T, ?[][]const u8),
        expected_name: ?[]const u8,
    ) CommandParseError!T {
        const num_fields = @typeInfo(T).Enum.fields.len;
        @setEvalBranchQuota(num_fields * 500);
        const infoMap = comptime initMap: {
            var res = explicit_aliases orelse std.enums.EnumMap(T, ?[][]const u8).initDefault(.{});
            inline for (std.meta.tags(T)) |arg| {
                if (res.get(arg) == null) {
                    res.set(arg, &[1][]const u8{
                        infer_default_from_enum_name(@tagName(arg)),
                    });
                }
            }
            break :initMap &res;
        };
        const total_potential_names = comptime countNames: {
            comptime var count = 0;
            var iter = infoMap.iterator();
            inline while (iter.next()) |entry| {
                const info = entry.value.*.?;
                count += info.len;
            }
            break :countNames count;
        };
        const argMap = comptime initArgMap: {
            const KV = struct {
                @"0": []const u8,
                @"1": T,
            };
            var values: [total_potential_names]KV = undefined;
            var iter = infoMap.iterator();
            var i = 0;
            inline while (iter.next()) |entry| {
                const names = entry.value.*.?;
                inline for (names) |name| {
                    values[i] = KV{
                        .@"0" = name,
                        .@"1" = entry.key,
                    };
                    i += 1;
                }
            }
            assert(i == total_potential_names);
            break :initArgMap std.ComptimeStringMap(T, values);
        };
        const arg = try self.*.expect_arg_string();
        if (argMap.get(arg)) |id| {
            return id;
        } else {
            return self.unexpected_arg_value(expected_name orelse @typeName(T));
        }
    }

    /// Expect a string argument, returning an error if there are not enough
    ///
    /// This can be used both for positional argument values and for flags.
    pub fn expect_arg_string(self: *Parser) CommandParseError![]const u8 {
        if (self.has_args()) {
            return self.next_arg() orelse unreachable;
        } else {
            self.error_info = CommandParseErrorInfo{ .insufficent_args = .{
                .expected = self.args.len + 1,
                .actual = self.args.len,
            } };
            return CommandParseError.CommandParseError;
        }
    }

    /// Expect an argument value of the specified type.
    ///
    /// Gives an error if the value is invalid,
    /// or if there are insufficient arguments.
    ///
    /// Only works with primitive value (and strings).
    ///
    /// This is a thin wrapper around `expect_string_arg
    pub fn expect_arg(
        self: *Parser,
        comptime T: type,
    ) CommandParseError!T {
        const arg = try self.expect_arg();
        return switch (@typeInfo(T)) {
            .Bool => {
                // TODO: Does not seem like a good idea
                if (std.mem.eql(u8, arg, "true")) {
                    return true;
                } else if (std.mem.eql(u8, arg, "false")) {
                    return false;
                } else {
                    return self.unexpexted_arg("a boolean");
                }
            },
            @typeInfo([]const u8) => arg,
            .Int => std.fmt.parseInt(T, arg) catch |err| {
                self.error_info = CommandParseErrorInfo{ .invalid_int = err };
                return CommandParseError.CommandParseError;
            },
            .Float => std.fmt.parseFloat(T, arg) catch |err| {
                self.error_info = CommandParseErrorInfo{ .invalid_float = err };
                return CommandParseError.CommandParseError;
            },
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        };
    }

    /// Give an error indicating the previous argument value is unexpected.
    ///
    /// Note this is the previous argument, not the current one.
    ///
    /// Safety-checked undefined behavior if currently
    pub fn unexpected_arg_value(self: *Parser, expected_value: []const u8) CommandParseError {
        const last_arg = self.args[self.current_arg_index - 1];
        self.error_info = CommandParseErrorInfo{ .unexpected_value = .{
            .expected = expected_value,
            .actual_text = last_arg,
        } };
        return CommandParseError.CommandParseError;
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

        pub fn infer_default(comptime arg: ArgId) @This() {
            return .{
                .arg = arg,
                .name = infer_default_from_enum_name(@tagName(arg)),
            };
        }

        pub fn matched_names(comptime self: *const @This()) [][]const u8 {
            var count: usize = 1;
            if (self.short != null) count += 1;
            count += self.aliases.len;
            var names: [count][]const u8 = undefined;
            names[0] = "--" ++ self.name;
            var i = 1;
            if (self.short) |short_char| {
                names[1] = &[2]u8{ '-', short_char };
                i += 1;
            }
            std.mem.copy([]const u8, names[i..], self.*.aliases);
            i += self.*.aliases.len;
            assert(i == count);
            return &names;
        }
    };
}

fn infer_default_from_enum_name(comptime name: []const u8) []const u8 {
    var normalized_name: [name.len]u8 = undefined;
    for (name) |c, i| {
        const normalized_char = switch (c) {
            '_' => '-',
            else => c, // TODO: Lowercase?
        };
        normalized_name[i] = normalized_char;
    }
    return &normalized_name;
}

const CommandParseErrorInfo = union(enum) {
    unknown_option: struct {
        arg: []const u8,
    },
    insufficent_args: struct { expected: usize, actual: usize },
    invalid_float: std.fmt.ParseFloatError,
    invalid_int: std.fmt.ParseIntError,
    unexpected_value: struct {
        expected: []const u8,
        actual_text: []const u8,
    },

    /// Print a desriptive error message to the specifeid writer.
    ///
    /// This does not include a newline
    pub fn write_desc(
        self: *const CommandParseErrorInfo,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        switch (self) {
            .unknown_option => |info| {
                try std.fmt.format(writer, "Unknown option `{s}`", .{info.arg});
            },
            .insufficent_args => |info| {
                try std.fmt.format(writer, "Expected {} positional args but only got {}", .{ info.expected, info.actual });
            },
        }
    }
};
pub const CommandParseError = error{
    CommandParseError,
};

test "parse implicit enums" {
    var args = Parser.init(&.{ "--foo", "--bar", "--potato" });
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
