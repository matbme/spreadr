const std = @import("std");
const files = @import("file.zig");
const ops = @import("operations.zig");

const clap = @import("clap");

const WholeFile = files.WholeFile;
const FileFragment = files.FileFragment;
const Allocator = std.mem.Allocator;

const Mode = enum { spread, join };

const ArgParseError = error{
    ClapError,
    InvalidMode,
    InvalidParams,
    InvalidInput,
};

const ParsedArgs = struct {
    // Common
    mode: Mode,
    output: ?[]const u8 = null,
    password: ?[]const u8 = null,
    verbose: bool = false,

    // spread
    n_frags: ?usize = null,
    spread_input_file: ?[]const u8 = null,

    // join
    join_input_files: ?[]const []const u8 = null,
};

fn print_help(params: []const clap.Param(clap.Help)) ArgParseError!void {
    const stderr = std.io.getStdErr().writer();

    stderr.writeAll(
        "Spread files across multiple, unreadable splits and vice-versa." ++
            "\n\nArguments:\n",
    ) catch unreachable;

    clap.help(stderr, clap.Help, params, .{
        .description_on_new_line = false,
        .description_indent = 4,
        .spacing_between_parameters = 0,
    }) catch return ArgParseError.ClapError;

    // TODO: Print example usage
}

fn parse_args(allocator: Allocator) ArgParseError!?ParsedArgs {
    const params = comptime clap.parseParamsComptime(
        \\<MODE>                Operation mode. Either 'spread' or 'join'.
        \\-o, --output   <str>  Operation output path. Defaults to 'spreadr_output'.
        \\-p, --password <str>  Password for spreading/reading fragments. If not provided, will be prompted when running.
        \\-n, --n_frags  <int> 'spread' mode only: Number of fragments to split the input into.
        \\-h, --help            Display this help and exit.
        \\-v, --verbose         Show detailed information.
        \\<FILE>...
    );

    const parsers = comptime .{
        .str = clap.parsers.string,
        .int = clap.parsers.int(usize, 10),
        .FILE = clap.parsers.string,
        .MODE = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return ArgParseError.ClapError;
    };
    defer res.deinit();

    if (res.args.help != 0 or res.positionals.len == 0) {
        try print_help(&params);
        return null;
    }

    const mode: Mode = def: {
        if (std.mem.eql(u8, res.positionals[0], "spread")) {
            break :def .spread;
        } else if (std.mem.eql(u8, res.positionals[0], "join")) {
            break :def .join;
        } else {
            std.io.getStdErr().writer().print("Mode must be either 'spread' or 'join', found {s}.\n", .{res.positionals[0]}) catch unreachable;
            return ArgParseError.InvalidMode;
        }
    };

    var parsed_args = ParsedArgs{ .mode = mode };

    // Input file(s)
    switch (res.positionals.len) {
        1 => {
            return ArgParseError.InvalidInput;
        },
        2 => {
            if (parsed_args.mode == .spread) {
                parsed_args.spread_input_file = res.positionals[1];
            } else {
                return ArgParseError.InvalidInput;
            }
        },
        else => {
            if (parsed_args.mode == .join) {
                parsed_args.join_input_files = res.positionals[1..];
            } else {
                return ArgParseError.InvalidInput;
            }
        },
    }

    // Common arguments
    if (res.args.output) |o| parsed_args.output = o;
    if (res.args.password) |p| parsed_args.password = p;
    if (res.args.verbose != 0) parsed_args.verbose = true;

    // spread-exclusive arguments
    if (res.args.n_frags) |nf| {
        if (parsed_args.mode == .spread) {
            parsed_args.n_frags = nf;
        } else {
            std.io.getStdErr().writeAll("Argument 'n_frags' is invalid in this mode.\n") catch unreachable;
            return ArgParseError.InvalidParams;
        }
    } else if (parsed_args.mode == .spread) {
        std.io.getStdErr().writeAll("Missing number of fragments. Please specify it via with '-n' or '--n_frags'.\n") catch unreachable;
        return ArgParseError.InvalidParams;
    }

    return parsed_args;
}

fn password_prompt(buffer: []u8) ![]const u8 {
    const stdout = std.io.getStdOut();
    const stdin = std.io.getStdIn();

    try stdout.writeAll("Please provide a password: ");

    var pass: ?[]const u8 = null;
    while (pass == null) {
        pass = try stdin.reader().readUntilDelimiterOrEof(buffer, '\n');

        if (pass == null)
            try std.io.getStdErr().writeAll("Password cannot be empty.\n");
    }

    return pass orelse unreachable;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = parse_args(allocator) catch |err| {
        if (err == ArgParseError.ClapError)
            try std.io.getStdErr().writeAll("Unexpected error while parsing arguments\n");
        std.posix.exit(1);
    };
    if (args == null)
        return;

    if (args.?.password == null) {
        var buf: [200]u8 = undefined;
        args.?.password = try password_prompt(&buf);
    }

    switch (args.?.mode) {
        .spread => {
            if (args.?.n_frags.? < 2) {
                try std.io.getStdErr().writeAll("Number of fragments must be at least 2\n");
                std.posix.exit(1);
            }

            try ops.split(allocator, &.{
                .input_path = args.?.spread_input_file.?,
                .output_path = args.?.output orelse "spreadr_output",
                .n_frags = args.?.n_frags.?,
                .password = args.?.password.?,
            });
        },
        .join => {
            try ops.join(allocator, &.{
                .output_path = args.?.output orelse "spreadr_output",
                .password = args.?.password.?,
                .fragment_paths = @constCast(args.?.join_input_files.?),
            });
        },
    }
}
