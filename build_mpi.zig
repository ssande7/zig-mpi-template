const std = @import("std");

pub const ShowMe = enum {
    incdirs,
    libdirs,
    libs,
    link,
    command,
};

/// Iterate through characters of `str`
fn nextChr(str: []const u8, i: *usize) u8 {
    i.* += 1;
    const out = blk: {
        if (i.* < str.len) {
            break :blk str[i.*];
        }
        break :blk 0;
    };
    return out;
}

/// Split `raw` by whitespace, skipping escaped spaces and respecting
/// double-quoted strings. Set `split` to `null` to query length.
/// If `split` is non-`null`, the contents of `raw` are modified
/// to strip out backslashes (apply one level of escaping)
fn splitStrings(raw: []u8, split: ?[][]u8) !u32 {
    if (raw.len == 0) {
        return 0;
    }
    // TODO: support single quotes? If so, worth cleaning up to avoid extra duplication.
    const State = enum {
        seeking,
        in_str_dquote,
        in_str_noquote,
    };

    var i: usize = 0;
    var i_str: u32 = 0;
    var chr: u8 = raw[0];
    var backslash = false;
    var str_start: usize = 0;
    parse: switch (State.seeking) {
        .seeking => {
            if (chr == 0) {
                break :parse;
            }
            const is_ws = std.ascii.isWhitespace(chr);
            if (!is_ws) {
                str_start = i;
                const old_chr = chr;
                chr = nextChr(raw, &i);
                continue :parse switch (old_chr) {
                    '\"' => .in_str_dquote,
                    '\\' => blk: {
                        backslash = true;
                        break :blk .in_str_noquote;
                    },
                    else => .in_str_noquote,
                };
            }
            chr = nextChr(raw, &i);
            continue :parse .seeking;
        },
        .in_str_dquote => {
            if (chr == 0) {
                return error.MissingEndQuote;
            }
            if (chr == '\"' and !backslash) {
                if (split) |splt| {
                    if (i_str >= splt.len) {
                        return error.BufferTooSmall;
                    }
                    splt[i_str] = raw[str_start + 1 .. i];
                }
                chr = nextChr(raw, &i);
                i_str += 1;
                continue :parse .seeking;
            }
            if (chr == '\\') {
                backslash = !backslash;
                chr = nextChr(raw, &i);
                continue :parse .in_str_dquote;
            }
            backslash = false;
            chr = nextChr(raw, &i);
            continue :parse .in_str_dquote;
        },
        .in_str_noquote => {
            if (chr == 0 or (std.ascii.isWhitespace(chr) and !backslash)) {
                if (split) |splt| {
                    if (i_str >= splt.len) {
                        return error.BufferTooSmall;
                    }
                    splt[i_str] = raw[str_start..i];
                }
                i_str += 1;
                if (chr == 0) {
                    break :parse;
                }
                chr = nextChr(raw, &i);
                continue :parse .seeking;
            }
            if (chr == '\\') {
                backslash = !backslash;
                chr = nextChr(raw, &i);
                continue :parse .in_str_noquote;
            }
            backslash = false;
            chr = nextChr(raw, &i);
            continue :parse .in_str_noquote;
        },
    }

    // Clean up backslashes
    if (split) |splt| {
        for (splt) |*str| {
            var w: usize = 0;
            var bs = false;
            for (str.*) |c| {
                if (c == '\\' and !bs) {
                    bs = true;
                } else {
                    bs = false;
                    str.*[w] = c;
                    w += 1;
                }
            }
            str.*.len = w;
        }
    }

    return i_str;
}

/// Get output of mpicc --showme:`arg`
pub fn showMe(comptime arg: ShowMe, b: *std.Build) [][]u8 {
    // Using b.allocator to get mpicc output, so can allow it to leak
    const mpicc = b.run(&.{ "mpicc", "--showme:" ++ @tagName(arg) });

    // Split output at whitespace, respecting double quotes and escaped spaces
    const n = splitStrings(mpicc, null) catch @panic("Failed to parse output of `mpicc --showme:" ++ @tagName(arg) ++ "`");
    const strings = b.allocator.alloc([]u8, n) catch @panic("OOM");
    _ = splitStrings(mpicc, strings) catch unreachable;

    return strings;
}

/// Find and link the MPI system library
pub fn linkMpi(b: *std.Build, bin: *std.Build.Step.Compile) void {
    // Add library directories. Maybe not needed?
    const libdirs = showMe(.libdirs, b);
    for (libdirs) |libdir| {
        bin.addLibraryPath(.{ .cwd_relative = libdir });
    }

    // Add rpath directories. Assumes linker flags prefixed with -Wl, (used by gcc to pass through)
    // TODO: Probably needs adjusting to account for other compilers (can check compiler with --showme:command)
    const linkargs = showMe(.link, b);
    var rpath = false;
    for (linkargs) |arg| {
        if (rpath) {
            if (!std.mem.startsWith(u8, arg, "-Wl,")) {
                @panic("Expected -Wl, prefix after -Wl,-rpath. This could be caused by an unknown linker.");
            }
            bin.addRPath(.{ .cwd_relative = arg[4..] });
            rpath = false;
        }
        if (std.mem.eql(u8, "-Wl,-rpath", arg)) {
            rpath = true;
        }
    }

    // Link MPI library and libc
    const libs = showMe(.libs, b);
    for (libs) |lib| {
        bin.linkSystemLibrary(lib);
    }
    bin.linkLibC();
}

/// For internal use - location of temporary patched mpi.h
var _tmp_mpi_h: ?[]const u8 = null;

/// Generate an mpi module to import into zig code
pub fn getMpiModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    // Set up temporary mpi.h file
    _tmp_mpi_h = std.fs.path.join(b.allocator, &.{ b.makeTempPath(), "mpi.h" }) catch @panic("OOM");

    // Add build step for generating patched mpi.h
    const patch_mpi = b.step("patch-mpi", "Patch mpi.h ready for translation");
    patch_mpi.makeFn = patchMpiH;

    // Add translation step
    const translate = b.addTranslateC(.{ .target = target, .optimize = optimize, .root_source_file = .{ .cwd_relative = _tmp_mpi_h.? } });
    translate.step.dependOn(patch_mpi);

    return translate.createModule();
}

/// Find system mpi.h and create a temporary patched version for translation.
/// Requires _tmp_mpi_h to be set to a writable path.
/// For OpenMPI: translate-c fails to properly translate OMPI_PREDEFINED_GLOBAL, so adjust
///              its definition and usage to something that works.
/// For others: untested...
fn patchMpiH(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    const b = step.owner;
    const progress = options.progress_node.start("Finding and patching mpi.h", 0);

    // Find system mpi.h
    const mpi_h = blk: {
        const incdirs = showMe(.incdirs, b);
        for (incdirs) |incdir| {
            const path = std.fs.path.join(b.allocator, &.{ incdir, "mpi.h" }) catch @panic("Failed to construct MPI header path");
            std.fs.cwd().access(path, .{}) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => {},
            };
            break :blk path;
        }
        @panic("Failed to find mpi.h");
    };
    progress.completeOne();

    // Read contents of mpi.h to buffer
    const stat = std.fs.cwd().statFile(mpi_h) catch @panic("Failed to stat mpi.h");
    const mpi_raw = std.fs.cwd().readFileAlloc(b.allocator, mpi_h, @as(usize, stat.size)) catch @panic("Error reading mpi.h");
    progress.completeOne();

    // Open temporary mpi.h to write patched version
    const fh = std.fs.cwd().createFile(_tmp_mpi_h orelse @panic("Output file path for mpi.h patching not set"), .{}) catch @panic("Failed to create cached mpi.h");
    defer fh.close();
    var bw = std.io.bufferedWriter(fh.writer());
    const writer = bw.writer();
    progress.completeOne();

    // Find lines to patch
    // TODO: Use match => action map to generalize.
    //       Cache locations of each match, sort, pop first, re-insert if next match exists
    var i: usize = 0;
    while (i < mpi_raw.len) {
        progress.completeOne();
        // Find where the macro is defined
        const DEFN_STR = "OMPI_PREDEFINED_GLOBAL(type, global) ((type) ((void *) &(global)))";
        const defn = std.mem.indexOf(u8, mpi_raw[i..], DEFN_STR);

        // Find macro usages - all use MPI_* types, but some have a preceding space, so check both
        var usage = std.mem.indexOf(u8, mpi_raw[i..], "OMPI_PREDEFINED_GLOBAL(MPI_");
        const usage2 = std.mem.indexOf(u8, mpi_raw[i..], "OMPI_PREDEFINED_GLOBAL( MPI_");
        if (usage != null and usage2 != null) {
            usage = @min(usage.?, usage2.?);
        } else if (usage2) |u| {
            usage = u;
        }

        // Nothing left, so write the remainder of the file contents
        if (defn == null and usage == null) {
            writer.writeAll(mpi_raw[i..]) catch @panic("Error writing mpi.h");
            break;
        }

        // Add explicit reference to macro usage to avoid needing to pass opaque type to zig fn
        if (defn == null or defn.? > usage.?) {
            const comma = std.mem.indexOf(u8, mpi_raw[i + usage.? ..], ",") orelse @panic("Error parsing mpi.h - failed to find comma in OMPI_PREDEFINED_GLOBAL usage");
            var offset: usize = 1;
            while (std.ascii.isWhitespace(mpi_raw[i + usage.? + comma + offset])) {
                offset += 1;
            }
            writer.writeAll(mpi_raw[i..][0..(usage.? + comma + offset)]) catch @panic("Error writing mpi.h");
            writer.writeAll("&") catch @panic("Error writing mpi.h");
            i += usage.? + comma + offset;
            continue;
        }

        // Replace macro definition with one which will be translated correctly
        writer.writeAll(mpi_raw[i..][0..defn.?]) catch @panic("Error writing mpi.h");
        writer.writeAll("OMPI_PREDEFINED_GLOBAL(type, global) (type)(global)") catch @panic("Error writing mpi.h");
        i += defn.? + DEFN_STR.len;
    }
    bw.flush() catch @panic("Error writing mpi.h");
    progress.end();
}

test "parse string split" {
    const raw = "foo /bar/baz asdf\\ fdsa \"/quoted/ asdf\\\"fdsa\"";
    var test_raw: [raw.len]u8 = undefined;
    @memcpy(&test_raw, raw);
    const num_strings = try splitStrings(&test_raw, null);
    try std.testing.expectEqual(@as(u32, 4), num_strings);
    const buf = try std.testing.allocator.alloc([]u8, num_strings);
    defer std.testing.allocator.free(buf);
    _ = try splitStrings(&test_raw, buf);
    try std.testing.expectEqualStrings("foo", buf[0]);
    try std.testing.expectEqualStrings("/bar/baz", buf[1]);
    try std.testing.expectEqualStrings("asdf fdsa", buf[2]);
    try std.testing.expectEqualStrings("/quoted/ asdf\"fdsa", buf[3]);
}
