//! A package representing multiple modules.
//!
//! This is slightly more broad than just a Roc "package", as this can
//! represent a package, platform, or even an app with modules.

const std = @import("std");
const collections = @import("../collections.zig");
const path = std.fs.path;
const Region = @import("Region.zig");

const exitOnOom = collections.utils.exitOnOom;

const Self = @This();

const ROC_EXTENSION = ".roc";
const DEFAULT_MAIN_FILENAME = "main.roc";

/// The full download URL for the package,
/// including the name, content hash, and version.
download_url: []const u8,
/// The BLAKE3 hash of the tarball's contents.
content_hash: []const u8,
/// The (usually semantic) version of this package, AKA 1.2.3.
version_string: []const u8,
/// The absolute path to the root folder of this package.
absolute_dirpath: []const u8,
/// All well-named Roc modules in this package,
/// irrespective if they are referenced at all from the root.
modules: Module.List,
/// Usually `main.roc`, or sometimes the application, e.g. `my-script.roc`.
root_module_idx: Module.Idx,
/// All files in this package (including the Roc ones) relative to the package's root.
relative_filepaths: std.ArrayList([]const u8),
/// All packages depended on by this package.
dependencies: Dependency.List,

const List = collections.SafeList(@This());
pub const Idx = List.Idx;

/// A .roc file within a package.
pub const Module = struct {
    /// The full name of a module, e.g. `Foo.Bar`.
    ///
    /// This is empty if the filepath is not a standard module,
    /// e.g. `main.roc` or `script.roc`, AKA modules that aren't importable.
    name: []const u8,
    /// The absolute path to this module minus the folder path
    /// for the package's source code root.
    ///
    /// Though we could calculate this from the name whenever we need it,
    /// that would take an allocation that we'd like to avoid.
    filepath_relative_to_package_root: []const u8,

    pub const List = collections.SafeList(@This());
    pub const Idx = Module.List.Idx;

    pub const NameError = error{
        BadPathName,
        non_ascii_path,
        empty_name,
        empty_name_segment,
        dot_in_path,
        invalid_extension,
    };

    /// Parse a package module given its relative path from the package's root dir.
    pub fn fromRelativePath(
        relative_path: []const u8,
        string_arena: *std.heap.ArenaAllocator,
    ) NameError!Module {
        var component_iter = try std.fs.path.componentIterator(relative_path);
        if (component_iter.peekNext() == null) {
            return error.empty_name;
        }

        // The filepath should always be `Path/To/Module.roc`, meaning we can just
        // replace the separators (the / in this example) with dots and remove
        // the last four characters for the extension.
        std.debug.assert(relative_path.len > ROC_EXTENSION.len);
        var name = string_arena.allocator().alloc(u8, relative_path.len - ROC_EXTENSION.len) catch exitOnOom();
        var chars_added: usize = 0;

        while (component_iter.next()) |component| {
            if (component.name.len == 0) {
                return error.empty_name_segment;
            } else if (std.ascii.isLower(component.name[0])) {
                return Module{
                    .name = "",
                    .filepath_relative_to_package_root = relative_path,
                };
            }

            const not_last = component_iter.peekNext() != null;

            const segment = if (not_last) component.name else blk: {
                const extension = path.extension(component.name);
                if (extension.len == 0) {
                    break :blk component.name;
                } else if (std.mem.eql(u8, extension, ROC_EXTENSION)) {
                    break :blk path.stem(component.name);
                } else {
                    return error.invalid_extension;
                }
            };

            for (segment) |char| {
                if (char == '.') {
                    return error.dot_in_path;
                } else if (!std.ascii.isASCII(char)) {
                    // TODO: what is a legal module name?
                    return error.non_ascii_path;
                }
            }

            std.mem.copyForwards(u8, name[chars_added..], segment);
            chars_added += segment.len;
            if (not_last) {
                std.mem.copyForwards(u8, name[chars_added..], ".");
                chars_added += 1;
            }
        }

        return Module{
            .name = name,
            .filepath_relative_to_package_root = relative_path,
        };
    }
};

/// The URL for a package downloaded from the internet.
pub const Url = struct {
    /// Valid URLs must end in one of these:
    ///
    /// - .tar
    /// - .tar.gz
    /// - .tar.br
    const VALID_ARCHIVE_EXTENSIONS: [3][]const u8 = .{ ".tar", ".tar.gz", ".tar.br" };

    const ROC_EXTENSION = ".roc";

    /// Since the TLD (top level domain) `.zip` is now available, there is a new attack
    /// vector where malicous URLs can be used to confuse the reader.
    /// Example of a URL which would take you to example.zip:
    /// https://github.com∕kubernetes∕kubernetes∕archive∕refs∕tags∕@example.zip
    /// roc employs a checksum mechanism to prevent tampering with packages.
    /// Nevertheless we should avoid such issues earlier.
    /// You can read more here: https://medium.com/@bobbyrsec/the-dangers-of-googles-zip-tld-5e1e675e59a5
    const MISLEADING_CHARACTERS_IN_URL: [5]u32 = .{
        '@', // @ - For now we avoid usage of the @, to avoid the "tld zip" attack vector
        '\u{2044}', // U+2044 ==  ⁄ Fraction Slash
        '\u{2215}', // U+2215 ==  ∕ Division Slash
        '\u{FF0F}', // U+2215 == ／ Fullwidth Solidus
        '\u{29F8}', // U+29F8 == ⧸ Big Solidus
    };

    /// The full URL, which other fields in this struct are slices in.
    url: []const u8,
    /// The BLAKE3 hash of the tarball's contents. Also the .tar filename on disk.
    content_hash: []const u8,
    /// On disk, this will be the subfolder inside the cache dir where the package lives.
    cache_subdir: []const u8,
    /// The (usually semantic) version of this package.
    version: []const u8,

    pub const ParseErr = error{
        missing_https,
        misleading_character,
        invalid_archive_extension,
        missing_content_hash,
        missing_version,
    };

    /// Parse a package download URL into useful metadata.
    pub fn parse(url: []const u8) ParseErr!Url {
        const HTTPS_PREFIX = "https://";
        const starts_with_https = std.mem.eql(u8, url[0..HTTPS_PREFIX.len], HTTPS_PREFIX);
        const without_protocol = if (starts_with_https) url[0..HTTPS_PREFIX.len] else {
            return error.missing_https;
        };

        for (url) |url_char| {
            for (MISLEADING_CHARACTERS_IN_URL) |misleading_char| {
                if (url_char == misleading_char) {
                    return error.misleading_character;
                }
            }
        }

        const without_ext = for (VALID_ARCHIVE_EXTENSIONS) |valid_extension| {
            const extension = without_protocol[(without_protocol.len - valid_extension.len)..];
            if (std.mem.eql(u8, extension, valid_extension)) {
                break without_protocol[0..(without_protocol.len - valid_extension.len)];
            }
        } else {
            return error.invalid_archive_extension;
        };

        var slash_index = without_ext.len;
        const without_hash, const content_hash = while (slash_index > 0) {
            slash_index -= 1;
            if (without_ext[slash_index] != '/') continue;

            break .{ without_ext[0..slash_index], without_ext[(slash_index + 1)..] };
        } else {
            return error.missing_content_hash;
        };

        slash_index = without_hash.len;
        const version = while (slash_index > 0) {
            slash_index -= 1;
            if (without_hash[slash_index] != '/') continue;

            break without_hash[0..slash_index];
        } else {
            return error.missing_version;
        };

        return Url{
            .url = url,
            .cache_subdir = without_ext,
            .content_hash = content_hash,
            .version = version,
        };
    }

    test "url problem missing https" {
        const url = "http://example.com";
        try std.testing.expectError(error.missing_https, Url.parse(url));
    }

    // test "url_problem_misleading_characters" {
    //     const examples: [1][]const u8 = .{
    //         "https://user:password@example.com/",
    //         // "https://example.com⁄path",
    //         // "https://example.com\u{2044}path",
    //         // "https://example.com∕path",
    //         // "https://example.com\u{2215}path",
    //         // "https://example.com／path",
    //         // "https://example.com\u{ff0f}path",
    //         // "https://example.com⧸path",
    //         // "https://example.com\u{29f8}path",
    //     };

    //     for (examples) |url| {
    //         try std.testing.expectError(error.misleading_character, Url.parse(url));
    //     }
    // }

    test "url problem invalid archive extension" {
        const url = "https://example.com/filename.zip";
        try std.testing.expectError(error.invalid_archive_extension, Url.parse(url));

        const url2 = "https://example.com/filename.tar.zip";
        try std.testing.expectError(error.invalid_archive_extension, Url.parse(url2));
    }
};

pub const Dependency = struct {
    shorthand: []const u8,
    shorthand_region: Region,
    package: Pkg,

    pub const AddError = union(enum) {
        empty_shorthand,
        duplicate_shorthand: struct {
            original_region: Region,
            shadow_region: Region,
        },
        bad_url: Url.ParseErr,
    };

    pub const Pkg = union(enum) {
        idx: Idx,
        err: AddError,
    };

    pub const List = collections.SafeList(@This());
};

pub const Store = struct {
    packages: List,
    indices_by_url: std.StringHashMap(Idx),
    string_arena: std.heap.ArenaAllocator,

    pub const builtins_idx: Idx = @enumFromInt(0);
    pub const primary_idx: Idx = @enumFromInt(1);

    pub const InitResult = union(enum) {
        success: Store,
        err: Err,

        pub const Err = union(enum) {
            could_not_find_builtins_root_module,
            could_not_find_primary_root_module,
            invalid_builtin_module_name: struct {
                err: Module.NameError,
                filename: []const u8,
            },

            pub fn deinit(err: *Err, gpa: std.mem.Allocator) void {
                switch (err.*) {
                    .could_not_find_builtins_root_module => {},
                    .could_not_find_primary_root_module => {},
                    .invalid_builtin_module_name => |data| {
                        gpa.free(data.filename);
                    },
                }
            }
        };
    };

    pub fn init(
        primary_root_module_absdir: []const u8,
        primary_root_module_path: []const u8,
        primary_relative_filepaths: std.ArrayList([]const u8),
        builtin_filenames: std.ArrayList([]const u8),
        gpa: std.mem.Allocator,
    ) InitResult {
        var string_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer string_arena.deinit();

        var packages = List.init(gpa);
        errdefer packages.deinit();

        _ = packages.append(Self{
            .download_url = &.{},
            .content_hash = &.{},
            .version_string = &.{},
            // TODO: set this to the cache path for builtins once they are saved there.
            .absolute_dirpath = &.{},
            .modules = Module.List.init(gpa),
            // zero value during init
            .root_module_idx = @enumFromInt(0),
            .relative_filepaths = builtin_filenames,
            .dependencies = Dependency.List.init(gpa),
        });

        // TODO: implement compilation of builtins
        // var builtin_root_idx: ?Idx = null;
        // for (builtin_filenames.items) |builtin_filename| {
        //     const module = Module.fromRelativePath(builtin_filename, &string_arena) catch |err| {
        //         return .{ .err = .{ .invalid_builtin_module_name = .{
        //             .err = err,
        //             .filename = gpa.dupe(u8, builtin_filename) catch exitOnOom(),
        //         } } };
        //     };
        //     const module_idx = packages.items.items[0].modules.append(module);

        //     if (std.mem.eql(u8, builtin_filename, DEFAULT_MAIN_FILENAME)) {
        //         builtin_root_idx = module_idx;
        //     }
        // }

        // if (builtin_root_idx) |root_idx| {
        //     packages.items.items[0].root_module_idx = root_idx;
        // } else {
        //     return .{ .err = .could_not_find_builtins_root_module };
        // }

        _ = packages.append(Self{
            .download_url = &.{},
            .content_hash = &.{},
            .version_string = &.{},
            .absolute_dirpath = primary_root_module_absdir,
            .modules = Module.List.init(gpa),
            // zero value during init
            .root_module_idx = @enumFromInt(0),
            .relative_filepaths = primary_relative_filepaths,
            .dependencies = Dependency.List.init(gpa),
        });

        var primary_root_idx: ?Idx = null;
        for (primary_relative_filepaths.items) |relative_path| {
            // For now, assume that modules with invalid names can't be imported,
            // so we don't even load them.
            const module = Module.fromRelativePath(relative_path, &string_arena) catch continue;
            const module_idx = packages.items.items[1].modules.append(module);

            if (std.mem.eql(u8, relative_path, primary_root_module_path)) {
                primary_root_idx = module_idx;
            }
        }

        if (primary_root_idx) |root_idx| {
            packages.items.items[1].root_module_idx = root_idx;
        } else {
            return .{ .err = .could_not_find_primary_root_module };
        }

        return .{ .success = Store{
            .packages = packages,
            .indices_by_url = std.StringHashMap(Idx).init(gpa),
            .string_arena = string_arena,
        } };
    }

    pub fn deinit(self: *Store) void {
        for (self.packages.items.items) |*package| {
            package.modules.deinit();
            package.dependencies.deinit();
            package.relative_filepaths.deinit();
        }

        self.packages.deinit();
        self.indices_by_url.deinit();
        self.string_arena.deinit();
    }

    pub fn add(
        self: *Store,
        url_data: Url,
        absolute_dirpath: []const u8,
        root_module_filename: []const u8,
        relative_filepaths: std.ArrayList([]const u8),
        gpa: std.mem.Allocator,
    ) error{root_module_not_found}!Idx {
        var modules = Module.List.init(gpa);
        const dependencies = Dependency.List.init(gpa);

        var root_module_idx: ?Module.Idx = null;
        for (relative_filepaths.items) |filepath| {
            // For now, assume that modules with invalid names can't be imported,
            // so we don't even load them.
            const module = Module.fromRelativePath(
                filepath,
                &self.string_arena,
            ) catch continue;
            const module_idx = modules.append(module);

            if (std.mem.eql(u8, filepath, root_module_filename)) {
                root_module_idx = module_idx;
            }
        }

        const idx = self.packages.append(Self{
            .download_url = url_data.url,
            .content_hash = url_data.content_hash,
            .version_string = url_data.version,
            .absolute_dirpath = absolute_dirpath,
            .modules = modules,
            .root_module_idx = root_module_idx orelse
                return error.root_module_not_found,
            .relative_filepaths = relative_filepaths,
            .dependencies = dependencies,
        });

        self.indices_by_url.put(url_data.url, idx) catch exitOnOom();

        return idx;
    }

    pub fn findWithUrl(self: *const Store, url: []const u8) ?Idx {
        return self.indices_by_url.get(url);
    }

    pub fn addDependencyToPackage(
        self: *Store,
        parent_idx: Idx,
        child_idx: Idx,
        shorthand: []const u8,
        shorthand_region: Region,
    ) void {
        const idx = @intFromEnum(parent_idx);
        const pkg = &self.packages.items.items[idx];

        const dep_pkg: Dependency.Pkg = blk: {
            if (shorthand.len == 0) break :blk .{ .err = .empty_shorthand };

            for (pkg.dependencies.items.items) |dependency| {
                if (std.meta.eql(shorthand_region, dependency.shorthand_region)) {
                    break :blk .{ .err = .{ .duplicate_shorthand = .{
                        .original_region = dependency.shorthand_region,
                        .shadow_region = shorthand_region,
                    } } };
                }
            }

            break :blk .{ .idx = child_idx };
        };

        _ = pkg.dependencies.append(Dependency{
            .shorthand = shorthand,
            .shorthand_region = shorthand_region,
            .package = dep_pkg,
        });
    }
};
