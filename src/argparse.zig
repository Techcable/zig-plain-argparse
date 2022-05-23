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
        expected_name: []const u8,
    ) CommandParseError!T {
        const num_fields = @typeInfo(T).Enum.fields.len;
        @setEvalBranchQuota(num_fields * 500);
        const infoMap = comptime initMap: {
            var res = explicit_aliases orelse std.enums.EnumMap(T, ?[][]const u8).init(.{});
            inline for (std.meta.tags(T)) |arg| {
                if (res.get(arg) == null) {
                    var inferred = [1][]const u8{
                        infer_default_from_enum_name(@tagName(arg)),
                    };
                    res.put(arg, &inferred);
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
            return self.unexpected_arg_value(expected_name);
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
        const arg = try self.expect_arg_string();
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
            .Int => std.fmt.parseInt(T, arg, 0) catch |err| {
                self.error_info = CommandParseErrorInfo{ .invalid_int = .{
                    .cause = err,
                    .arg = arg,
                } };
                return CommandParseError.CommandParseError;
            },
            .Float => std.fmt.parseFloat(T, arg) catch |err| {
                self.error_info = CommandParseErrorInfo{ .invalid_float = .{
                    .cause = err,
                    .arg = arg,
                } };
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
    insufficent_args: struct {
        expected: usize,
        actual: usize,
    },
    invalid_float: struct {
        cause: std.fmt.ParseFloatError,
        arg: []const u8,
    },
    invalid_int: struct {
        cause: std.fmt.ParseIntError,
        arg: []const u8,
    },
    unexpected_value: struct {
        expected: []const u8,
        actual_text: []const u8,
    },

    /// Format this error information into the specified writer.
    ///
    /// This satisifies the "trait" for use with Zig `std.fmt` impl.
    pub fn format(
        self: *const CommandParseErrorInfo,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt; // TODO: Should we ignore like this
        _ = options;
        switch (self.*) {
            .unknown_option => |info| {
                try std.fmt.format(
                    writer,
                    "Unknown option `{s}`",
                    .{info.arg},
                );
            },
            .insufficent_args => |info| {
                try std.fmt.format(
                    writer,
                    "Expected {} positional args but only got {}",
                    .{ info.expected, info.actual },
                );
            },
            .invalid_float => |info| {
                try std.fmt.format(
                    writer,
                    "Invalid float `{s}` ({s})",
                    .{ info.arg, @errorName(info.cause) },
                );
            },
            .invalid_int => |info| {
                try std.fmt.format(
                    writer,
                    "Invalid integer `{s}` ({s})",
                    .{ info.arg, @errorName(info.cause) },
                );
            },
            .unexpected_value => |info| {
                try std.fmt.format(
                    writer,
                    "Invalid value `{s}`, expected {s}",
                    .{ info.actual_text, info.expected },
                );
            },
        }
    }
};
pub const CommandParseError = error{
    CommandParseError,
};

test "parse enums" {
    var args = Parser.init(&.{ "--foo", "--bar", "--potato", "poopy", "pants" });
    var foo = false;
    var bar = false;
    var potato = false;
    // Notice how the enum type is implicit here.
    //
    // can't get much simpler than that
    while (try args.match_flag_enum(
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
    try std.testing.expect(!args.has_flag_args());
    const Value = enum {
        poopy,
        potato,
        pants,
        your_mother,
    };
    var values = std.ArrayList(Value).init(std.testing.allocator);
    defer values.deinit();
    while (args.has_args()) {
        const value = try args.expect_arg_value_enum(
            Value,
            null,
            "test enum value",
        );
        try values.append(value);
    }
    try std.testing.expect(!args.has_args());
    try std.testing.expect(foo);
    try std.testing.expect(bar);
    try std.testing.expect(potato);
}

test "unknown option errors" {
    // test "unknown option" error
    //
    // NOTE: For some reason the `expectEqual` needs
    // to be run at comptime...
    const error_info = comptime initErr: {
        var args = Parser.init(&.{
            "--invalid",
            "--bar",
        });
        try std.testing.expectError(
            CommandParseError.CommandParseError,
            args.match_flag_enum(
                enum { foo, bar },
                &.{},
            ),
        );
        try std.testing.expectEqual(
            CommandParseErrorInfo{
                .unknown_option = .{ .arg = "--invalid" },
            },
            args.error_info.?,
        );
        break :initErr args.error_info.?;
    };
    // However this must be done at runtime, because it allocatesa
    try std.testing.expectFmt(
        "Unknown option `--invalid`",
        "{}",
        .{error_info},
    );
}

test "invalid value errors" {
    // test "unknown value" error
    //
    // NOTE: For some reason the `expectEqual` needs
    // to be run at comptime...
    const TestData = struct {
        tp: type,
        expected_err: CommandParseErrorInfo,
        expected_err_msg: []const u8,
    };
    const TestEnum = enum {
        foo,
        bar,
        baz,
    };
    const fake_args = &[_][]const u8{ "potato", "taco" };
    const tests = &[_]TestData{
        .{
            .tp = i32,
            .expected_err = CommandParseErrorInfo{
                .invalid_int = .{
                    .cause = std.fmt.ParseIntError.InvalidCharacter,
                    .arg = "potato",
                },
            },
            .expected_err_msg = "Invalid integer `potato` (InvalidCharacter)",
        },
        .{
            .tp = f64,
            .expected_err = CommandParseErrorInfo{
                .invalid_float = .{
                    .cause = std.fmt.ParseFloatError.InvalidCharacter,
                    .arg = "potato",
                },
            },
            .expected_err_msg = "Invalid float `potato` (InvalidCharacter)",
        },
        .{
            .tp = TestEnum,
            .expected_err = CommandParseErrorInfo{
                .unexpected_value = .{
                    .expected = "TestEnum",
                    .actual_text = "potato",
                },
            },
            .expected_err_msg = "Invalid value `potato`, expected a TestEnum",
        },
    };
    inline for (tests) |test_data| {
        var args = Parser.init(fake_args);
        const res = switch (@typeInfo(test_data.tp)) {
            .Enum => args.expect_arg_value_enum(
                test_data.tp,
                null,
                "a " ++ @typeName(test_data.tp),
            ),
            .Int, .Float => args.expect_arg(test_data.tp),
            else => unreachable,
        };
        try std.testing.expectError(CommandParseError.CommandParseError, res);
        // TODO: Compare struct equality???
        try std.testing.expectEqual(
            std.meta.activeTag(test_data.expected_err),
            std.meta.activeTag(args.error_info.?),
        );
        // However this must be done at runtime, because it allocatesa
        try std.testing.expectFmt(
            test_data.expected_err_msg,
            "{}",
            .{args.error_info.?},
        );
    }
}
