const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const process = std.process;

const backend = @import("backend");
const Assembly = backend.Assembly;
const Ir = backend.Ir;
const Object = backend.Object;

const Compilation = @import("Compilation.zig");
const Diagnostics = @import("Diagnostics.zig");
const GCCVersion = @import("Driver/GCCVersion.zig");
const LangOpts = @import("LangOpts.zig");
const Preprocessor = @import("Preprocessor.zig");
const Source = @import("Source.zig");
const target_util = @import("target.zig");
const Toolchain = @import("Toolchain.zig");
const Tree = @import("Tree.zig");

const AsmCodeGenFn = fn (target: std.Target, tree: *const Tree) Compilation.Error!Assembly;

pub const Linker = enum {
    ld,
    bfd,
    gold,
    lld,
    mold,
};

const pic_related_options = std.StaticStringMap(void).initComptime(.{
    .{"-fpic"},
    .{"-fno-pic"},
    .{"-fPIC"},
    .{"-fno-PIC"},
    .{"-fpie"},
    .{"-fno-pie"},
    .{"-fPIE"},
    .{"-fno-PIE"},
});

const Driver = @This();

comp: *Compilation,
diagnostics: *Diagnostics,

inputs: std.ArrayListUnmanaged(Source) = .{},
link_objects: std.ArrayListUnmanaged([]const u8) = .{},
output_name: ?[]const u8 = null,
sysroot: ?[]const u8 = null,
resource_dir: ?[]const u8 = null,
system_defines: Compilation.SystemDefinesMode = .include_system_defines,
temp_file_count: u32 = 0,
/// If false, do not emit line directives in -E mode
line_commands: bool = true,
/// If true, use `#line <num>` instead of `# <num>` for line directives
use_line_directives: bool = false,
only_preprocess: bool = false,
only_syntax: bool = false,
only_compile: bool = false,
only_preprocess_and_compile: bool = false,
verbose_ast: bool = false,
verbose_pp: bool = false,
verbose_ir: bool = false,
verbose_linker_args: bool = false,
color: ?bool = null,
nobuiltininc: bool = false,
nostdinc: bool = false,
nostdlibinc: bool = false,
apple_kext: bool = false,
mkernel: bool = false,
mabicalls: ?bool = null,
dynamic_nopic: ?bool = null,
ropi: bool = false,
rwpi: bool = false,
cmodel: std.builtin.CodeModel = .default,
debug_dump_letters: packed struct(u3) {
    d: bool = false,
    m: bool = false,
    n: bool = false,

    /// According to GCC, specifying letters whose behavior conflicts is undefined.
    /// We follow clang in that `-dM` always takes precedence over `-dD`
    pub fn getPreprocessorDumpMode(self: @This()) Preprocessor.DumpMode {
        if (self.m) return .macros_only;
        if (self.d) return .macros_and_result;
        if (self.n) return .macro_names_and_result;
        return .result_only;
    }
} = .{},

/// Full path to the aro executable
aro_name: []const u8 = "",

/// Value of --triple= passed via CLI
raw_target_triple: ?[]const u8 = null,

/// Non-optimizing assembly backend is currently selected by passing `-O0`
use_assembly_backend: bool = false,

// linker options
use_linker: ?[]const u8 = null,
linker_path: ?[]const u8 = null,
nodefaultlibs: bool = false,
nolibc: bool = false,
nostartfiles: bool = false,
nostdlib: bool = false,
pie: ?bool = null,
rdynamic: bool = false,
relocatable: bool = false,
rtlib: ?[]const u8 = null,
shared: bool = false,
shared_libgcc: bool = false,
static: bool = false,
static_libgcc: bool = false,
static_pie: bool = false,
strip: bool = false,
unwindlib: ?[]const u8 = null,

pub fn deinit(d: *Driver) void {
    for (d.link_objects.items[d.link_objects.items.len - d.temp_file_count ..]) |obj| {
        std.fs.deleteFileAbsolute(obj) catch {};
        d.comp.gpa.free(obj);
    }
    d.inputs.deinit(d.comp.gpa);
    d.link_objects.deinit(d.comp.gpa);
    d.* = undefined;
}

pub const usage =
    \\Usage {s}: [options] file..
    \\
    \\General options:
    \\  --help      Print this message
    \\  --version   Print aro version
    \\
    \\Compile options:
    \\  -c, --compile           Only run preprocess, compile, and assemble steps
    \\  -dM                     Output #define directives for all the macros defined during the execution of the preprocessor
    \\  -dD                     Like -dM except that it outputs both the #define directives and the result of preprocessing
    \\  -dN                     Like -dD, but emit only the macro names, not their expansions.
    \\  -D <macro>=<value>      Define <macro> to <value> (defaults to 1)
    \\  -E                      Only run the preprocessor
    \\  -fapple-kext            Use Apple's kernel extensions ABI
    \\  -fchar8_t               Enable char8_t (enabled by default in C23 and later)
    \\  -fno-char8_t            Disable char8_t (disabled by default for pre-C23)
    \\  -fcolor-diagnostics     Enable colors in diagnostics
    \\  -fno-color-diagnostics  Disable colors in diagnostics
    \\  -fcommon                Place uninitialized global variables in a common block
    \\  -fno-common             Place uninitialized global variables in the BSS section of the object file
    \\  -fdeclspec              Enable support for __declspec attributes
    \\  -fgnuc-version=<value>  Controls value of __GNUC__ and related macros. Set to 0 or empty to disable them.
    \\  -fno-declspec           Disable support for __declspec attributes
    \\  -ffp-eval-method=[source|double|extended]
    \\                          Evaluation method to use for floating-point arithmetic
    \\  -ffreestanding          Compilation in a freestanding environment
    \\  -fgnu-inline-asm        Enable GNU style inline asm (default: enabled)
    \\  -fno-gnu-inline-asm     Disable GNU style inline asm
    \\  -fhosted                Compilation in a hosted environment
    \\  -fms-extensions         Enable support for Microsoft extensions
    \\  -fno-ms-extensions      Disable support for Microsoft extensions
    \\  -fdollars-in-identifiers
    \\                          Allow '$' in identifiers
    \\  -fno-dollars-in-identifiers
    \\                          Disallow '$' in identifiers
    \\  -g                      Generate debug information
    \\  -fmacro-backtrace-limit=<limit>
    \\                          Set limit on how many macro expansion traces are shown in errors (default 6)
    \\  -fnative-half-type      Use the native half type for __fp16 instead of promoting to float
    \\  -fnative-half-arguments-and-returns
    \\                          Allow half-precision function arguments and return values
    \\  -fpic                   Generate position-independent code (PIC) suitable for use in a shared library, if supported for the target machine
    \\  -fPIC                   Similar to -fpic but avoid any limit on the size of the global offset table
    \\  -fpie                   Similar to -fpic, but the generated position-independent code can only be linked into executables
    \\  -fPIE                   Similar to -fPIC, but the generated position-independent code can only be linked into executables
    \\  -frwpi                  Generate read-write position independent code (ARM only)
    \\  -fno-rwpi               Disable generate read-write position independent code (ARM only).
    \\  -fropi                  Generate read-only position independent code (ARM only)
    \\  -fno-ropi               Disable generate read-only position independent code (ARM only).
    \\  -fshort-enums           Use the narrowest possible integer type for enums
    \\  -fno-short-enums        Use "int" as the tag type for enums
    \\  -fsigned-char           "char" is signed
    \\  -fno-signed-char        "char" is unsigned
    \\  -fsyntax-only           Only run the preprocessor, parser, and semantic analysis stages
    \\  -funsigned-char         "char" is unsigned
    \\  -fno-unsigned-char      "char" is signed
    \\  -fuse-line-directives   Use `#line <num>` linemarkers in preprocessed output
    \\  -fno-use-line-directives
    \\                          Use `# <num>` linemarkers in preprocessed output
    \\  -I <dir>                Add directory to include search path
    \\  -idirafter <dir>        Add directory to AFTER include search path
    \\  -isystem <dir>          Add directory to SYSTEM include search path
    \\  -F <dir>                Add directory to macOS framework search path
    \\  -iframework <dir>       Add directory to SYSTEM macOS framework search path
    \\  --embed-dir=<dir>       Add directory to `#embed` search path
    \\  --emulate=[clang|gcc|msvc]
    \\                          Select which C compiler to emulate (default clang)
    \\  -mabicalls              Enable SVR4-style position-independent code (Mips only)
    \\  -mno-abicalls           Disable SVR4-style position-independent code (Mips only)
    \\  -mcmodel=<code-model>   Generate code for the given code model
    \\  -mkernel                Enable kernel development mode
    \\  -nobuiltininc           Do not search the compiler's builtin directory for include files
    \\  -resource-dir <dir>     Override the path to the compiler's builtin resource directory
    \\  -nostdinc, --no-standard-includes
    \\                          Do not search the standard system directories or compiler builtin directories for include files.
    \\  -nostdlibinc            Do not search the standard system directories for include files, but do search compiler builtin include directories
    \\  -o <file>               Write output to <file>
    \\  -P, --no-line-commands  Disable linemarker output in -E mode
    \\  -pedantic               Warn on language extensions
    \\  -pedantic-errors        Error on language extensions
    \\  --rtlib=<arg>           Compiler runtime library to use (libgcc or compiler-rt)
    \\  -std=<standard>         Specify language standard
    \\  -S, --assemble          Only run preprocess and compilation steps
    \\  --sysroot=<dir>         Use dir as the logical root directory for headers and libraries (not fully implemented)
    \\  --target=<value>        Generate code for the given target
    \\  -U <macro>              Undefine <macro>
    \\  -undef                  Do not predefine any system-specific macros. Standard predefined macros remain defined.
    \\  -w                      Ignore all warnings
    \\  -Werror                 Treat all warnings as errors
    \\  -Werror=<warning>       Treat warning as error
    \\  -W<warning>             Enable the specified warning
    \\  -Wno-<warning>          Disable the specified warning
    \\
    \\Link options:
    \\  -fuse-ld=[bfd|gold|lld|mold]
    \\                          Use specific linker
    \\  -nodefaultlibs          Do not use the standard system libraries when linking.
    \\  -nolibc                 Do not use the C library or system libraries tightly coupled with it when linking.
    \\  -nostdlib               Do not use the standard system startup files or libraries when linking
    \\  -nostartfiles           Do not use the standard system startup files when linking.
    \\  -pie                    Produce a dynamically linked position independent executable on targets that support it.
    \\  --ld-path=<path>        Use linker specified by <path>
    \\  -r                      Produce a relocatable object as output.
    \\  -rdynamic               Pass the flag -export-dynamic to the ELF linker, on targets that support it.
    \\  -s                      Remove all symbol table and relocation information from the executable.
    \\  -shared                 Produce a shared object which can then be linked with other objects to form an executable.
    \\  -shared-libgcc          On systems that provide libgcc as a shared library, force the use of the shared version
    \\  -static                 On systems that support dynamic linking, this overrides -pie and prevents linking with the shared libraries.
    \\  -static-libgcc          On systems that provide libgcc as a shared library, force the use of the static version
    \\  -static-pie             Produce a static position independent executable on targets that support it.
    \\  --unwindlib=<arg>       Unwind library to use ("none", "libgcc", or "libunwind") If not specified, will match runtime library
    \\
    \\Debug options:
    \\  --verbose-ast           Dump produced AST to stdout
    \\  --verbose-pp            Dump preprocessor state
    \\  --verbose-ir            Dump ir to stdout
    \\  --verbose-linker-args   Dump linker args to stdout
    \\
    \\
;

/// Process command line arguments, returns true if something was written to std_out.
pub fn parseArgs(
    d: *Driver,
    std_out: anytype,
    macro_buf: anytype,
    args: []const []const u8,
) Compilation.Error!bool {
    var i: usize = 1;
    var comment_arg: []const u8 = "";
    var hosted: ?bool = null;
    var gnuc_version: []const u8 = "4.2.1"; // default value set by clang
    var pic_arg: []const u8 = "";
    var declspec_attrs: ?bool = null;
    var ms_extensions: ?bool = null;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.startsWith(u8, arg, "-") and arg.len > 1) {
            if (mem.eql(u8, arg, "--help")) {
                std_out.print(usage, .{args[0]}) catch |er| {
                    return d.fatal("unable to print usage: {s}", .{errorDescription(er)});
                };
                return true;
            } else if (mem.eql(u8, arg, "--version")) {
                std_out.writeAll(@import("backend").version_str ++ "\n") catch |er| {
                    return d.fatal("unable to print version: {s}", .{errorDescription(er)});
                };
                return true;
            } else if (mem.startsWith(u8, arg, "-D")) {
                var macro = arg["-D".len..];
                if (macro.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        try d.err("expected argument after -D", .{});
                        continue;
                    }
                    macro = args[i];
                }
                var value: []const u8 = "1";
                if (mem.indexOfScalar(u8, macro, '=')) |some| {
                    value = macro[some + 1 ..];
                    macro = macro[0..some];
                }
                try macro_buf.print("#define {s} {s}\n", .{ macro, value });
            } else if (mem.startsWith(u8, arg, "-U")) {
                var macro = arg["-U".len..];
                if (macro.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        try d.err("expected argument after -U", .{});
                        continue;
                    }
                    macro = args[i];
                }
                try macro_buf.print("#undef {s}\n", .{macro});
            } else if (mem.eql(u8, arg, "-O")) {
                d.comp.code_gen_options.optimization_level = .@"0";
            } else if (mem.startsWith(u8, arg, "-O")) {
                d.comp.code_gen_options.optimization_level = backend.CodeGenOptions.OptimizationLevel.fromString(arg["-O".len..]) orelse {
                    try d.err("invalid optimization level '{s}'", .{arg});
                    continue;
                };
                d.use_assembly_backend = d.comp.code_gen_options.optimization_level == .@"0";
            } else if (mem.eql(u8, arg, "-undef")) {
                d.system_defines = .no_system_defines;
            } else if (mem.eql(u8, arg, "-c") or mem.eql(u8, arg, "--compile")) {
                d.only_compile = true;
            } else if (mem.eql(u8, arg, "-dD")) {
                d.debug_dump_letters.d = true;
            } else if (mem.eql(u8, arg, "-dM")) {
                d.debug_dump_letters.m = true;
            } else if (mem.eql(u8, arg, "-dN")) {
                d.debug_dump_letters.n = true;
            } else if (mem.eql(u8, arg, "-E")) {
                d.only_preprocess = true;
            } else if (mem.eql(u8, arg, "-P") or mem.eql(u8, arg, "--no-line-commands")) {
                d.line_commands = false;
            } else if (mem.eql(u8, arg, "-fuse-line-directives")) {
                d.use_line_directives = true;
            } else if (mem.eql(u8, arg, "-fno-use-line-directives")) {
                d.use_line_directives = false;
            } else if (mem.eql(u8, arg, "-fapple-kext")) {
                d.apple_kext = true;
            } else if (option(arg, "-mcmodel=")) |cmodel| {
                d.cmodel = std.meta.stringToEnum(std.builtin.CodeModel, cmodel) orelse
                    return d.fatal("unsupported machine code model: '{s}'", .{arg});
            } else if (mem.eql(u8, arg, "-mkernel")) {
                d.mkernel = true;
            } else if (mem.eql(u8, arg, "-mdynamic-no-pic")) {
                d.dynamic_nopic = true;
            } else if (mem.eql(u8, arg, "-mabicalls")) {
                d.mabicalls = true;
            } else if (mem.eql(u8, arg, "-mno-abicalls")) {
                d.mabicalls = false;
            } else if (mem.eql(u8, arg, "-fchar8_t")) {
                d.comp.langopts.has_char8_t_override = true;
            } else if (mem.eql(u8, arg, "-fno-char8_t")) {
                d.comp.langopts.has_char8_t_override = false;
            } else if (mem.eql(u8, arg, "-fcolor-diagnostics")) {
                d.color = true;
            } else if (mem.eql(u8, arg, "-fno-color-diagnostics")) {
                d.color = false;
            } else if (mem.eql(u8, arg, "-fcommon")) {
                d.comp.code_gen_options.common = true;
            } else if (mem.eql(u8, arg, "-fno-common")) {
                d.comp.code_gen_options.common = false;
            } else if (mem.eql(u8, arg, "-fdollars-in-identifiers")) {
                d.comp.langopts.dollars_in_identifiers = true;
            } else if (mem.eql(u8, arg, "-fno-dollars-in-identifiers")) {
                d.comp.langopts.dollars_in_identifiers = false;
            } else if (mem.eql(u8, arg, "-g")) {
                d.comp.code_gen_options.debug = true;
            } else if (mem.eql(u8, arg, "-g0")) {
                d.comp.code_gen_options.debug = false;
            } else if (mem.eql(u8, arg, "-fdigraphs")) {
                d.comp.langopts.digraphs = true;
            } else if (mem.eql(u8, arg, "-fno-digraphs")) {
                d.comp.langopts.digraphs = false;
            } else if (mem.eql(u8, arg, "-fgnu-inline-asm")) {
                d.comp.langopts.gnu_asm = true;
            } else if (mem.eql(u8, arg, "-fno-gnu-inline-asm")) {
                d.comp.langopts.gnu_asm = false;
            } else if (option(arg, "-fmacro-backtrace-limit=")) |limit_str| {
                var limit = std.fmt.parseInt(u32, limit_str, 10) catch {
                    try d.err("-fmacro-backtrace-limit takes a number argument", .{});
                    continue;
                };

                if (limit == 0) limit = std.math.maxInt(u32);
                d.diagnostics.macro_backtrace_limit = limit;
            } else if (mem.eql(u8, arg, "-fnative-half-type")) {
                d.comp.langopts.use_native_half_type = true;
            } else if (mem.eql(u8, arg, "-fnative-half-arguments-and-returns")) {
                d.comp.langopts.allow_half_args_and_returns = true;
            } else if (pic_related_options.has(arg)) {
                pic_arg = arg;
            } else if (mem.eql(u8, arg, "-fropi")) {
                d.ropi = true;
            } else if (mem.eql(u8, arg, "-fno-ropi")) {
                d.ropi = false;
            } else if (mem.eql(u8, arg, "-frwpi")) {
                d.rwpi = true;
            } else if (mem.eql(u8, arg, "-fno-rwpi")) {
                d.rwpi = false;
            } else if (mem.eql(u8, arg, "-fshort-enums")) {
                d.comp.langopts.short_enums = true;
            } else if (mem.eql(u8, arg, "-fno-short-enums")) {
                d.comp.langopts.short_enums = false;
            } else if (mem.eql(u8, arg, "-fsigned-char")) {
                d.comp.langopts.setCharSignedness(.signed);
            } else if (mem.eql(u8, arg, "-fno-signed-char")) {
                d.comp.langopts.setCharSignedness(.unsigned);
            } else if (mem.eql(u8, arg, "-funsigned-char")) {
                d.comp.langopts.setCharSignedness(.unsigned);
            } else if (mem.eql(u8, arg, "-fno-unsigned-char")) {
                d.comp.langopts.setCharSignedness(.signed);
            } else if (mem.eql(u8, arg, "-fdeclspec")) {
                declspec_attrs = true;
            } else if (mem.eql(u8, arg, "-fno-declspec")) {
                declspec_attrs = false;
            } else if (mem.eql(u8, arg, "-ffreestanding")) {
                hosted = false;
            } else if (mem.eql(u8, arg, "-fhosted")) {
                hosted = true;
            } else if (mem.eql(u8, arg, "-fms-extensions")) {
                ms_extensions = true;
            } else if (mem.eql(u8, arg, "-fno-ms-extensions")) {
                ms_extensions = false;
            } else if (mem.startsWith(u8, arg, "-fsyntax-only")) {
                d.only_syntax = true;
            } else if (mem.startsWith(u8, arg, "-fno-syntax-only")) {
                d.only_syntax = false;
            } else if (mem.eql(u8, arg, "-fgnuc-version=")) {
                gnuc_version = "0";
            } else if (option(arg, "-fgnuc-version=")) |version| {
                gnuc_version = version;
            } else if (mem.startsWith(u8, arg, "-I")) {
                var path = arg["-I".len..];
                if (path.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        try d.err("expected argument after -I", .{});
                        continue;
                    }
                    path = args[i];
                }
                try d.comp.include_dirs.append(d.comp.gpa, path);
            } else if (mem.startsWith(u8, arg, "-idirafter")) {
                var path = arg["-idirafter".len..];
                if (path.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        try d.err("expected argument after -idirafter", .{});
                        continue;
                    }
                    path = args[i];
                }
                try d.comp.after_include_dirs.append(d.comp.gpa, path);
            } else if (mem.startsWith(u8, arg, "-isystem")) {
                var path = arg["-isystem".len..];
                if (path.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        try d.err("expected argument after -isystem", .{});
                        continue;
                    }
                    path = args[i];
                }
                try d.comp.system_include_dirs.append(d.comp.gpa, path);
            } else if (mem.startsWith(u8, arg, "-F")) {
                var path = arg["-F".len..];
                if (path.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        try d.err("expected argument after -F", .{});
                        continue;
                    }
                    path = args[i];
                }
                try d.comp.framework_dirs.append(d.comp.gpa, path);
            } else if (mem.startsWith(u8, arg, "-iframework")) {
                var path = arg["-iframework".len..];
                if (path.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        try d.err("expected argument after -iframework", .{});
                        continue;
                    }
                    path = args[i];
                }
                try d.comp.system_framework_dirs.append(d.comp.gpa, path);
            } else if (option(arg, "--embed-dir=")) |path| {
                try d.comp.embed_dirs.append(d.comp.gpa, path);
            } else if (option(arg, "--emulate=")) |compiler_str| {
                const compiler = std.meta.stringToEnum(LangOpts.Compiler, compiler_str) orelse {
                    try d.err("invalid compiler '{s}'", .{arg});
                    continue;
                };
                d.comp.langopts.setEmulatedCompiler(compiler);
                switch (d.comp.langopts.emulate) {
                    .clang => try d.diagnostics.set("clang", .off),
                    .gcc => try d.diagnostics.set("gnu", .off),
                    .msvc => try d.diagnostics.set("microsoft", .off),
                }
            } else if (option(arg, "-ffp-eval-method=")) |fp_method_str| {
                const fp_eval_method = std.meta.stringToEnum(LangOpts.FPEvalMethod, fp_method_str) orelse .indeterminate;
                if (fp_eval_method == .indeterminate) {
                    try d.err("unsupported argument '{s}' to option '-ffp-eval-method='; expected 'source', 'double', or 'extended'", .{fp_method_str});
                    continue;
                }
                d.comp.langopts.setFpEvalMethod(fp_eval_method);
            } else if (mem.startsWith(u8, arg, "-o")) {
                var file = arg["-o".len..];
                if (file.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        try d.err("expected argument after -o", .{});
                        continue;
                    }
                    file = args[i];
                }
                d.output_name = file;
            } else if (option(arg, "--sysroot=")) |sysroot| {
                d.sysroot = sysroot;
            } else if (mem.eql(u8, arg, "-pedantic")) {
                d.diagnostics.state.extensions = .warning;
            } else if (mem.eql(u8, arg, "-pedantic-errors")) {
                d.diagnostics.state.extensions = .@"error";
            } else if (mem.eql(u8, arg, "-w")) {
                d.diagnostics.state.ignore_warnings = true;
            } else if (option(arg, "--rtlib=")) |rtlib| {
                if (mem.eql(u8, rtlib, "compiler-rt") or mem.eql(u8, rtlib, "libgcc") or mem.eql(u8, rtlib, "platform")) {
                    d.rtlib = rtlib;
                } else {
                    try d.err("invalid runtime library name '{s}'", .{rtlib});
                }
            } else if (mem.eql(u8, arg, "-Wno-fatal-errors")) {
                d.diagnostics.state.fatal_errors = false;
            } else if (mem.eql(u8, arg, "-Wfatal-errors")) {
                d.diagnostics.state.fatal_errors = true;
            } else if (mem.eql(u8, arg, "-Wno-everything")) {
                d.diagnostics.state.enable_all_warnings = false;
            } else if (mem.eql(u8, arg, "-Weverything")) {
                d.diagnostics.state.enable_all_warnings = true;
            } else if (mem.eql(u8, arg, "-Werror")) {
                d.diagnostics.state.error_warnings = true;
            } else if (mem.eql(u8, arg, "-Wno-error")) {
                d.diagnostics.state.error_warnings = false;
            } else if (option(arg, "-Werror=")) |err_name| {
                try d.diagnostics.set(err_name, .@"error");
            } else if (option(arg, "-Wno-error=")) |err_name| {
                // TODO this should not set to warning if the option has not been specified.
                try d.diagnostics.set(err_name, .warning);
            } else if (option(arg, "-Wno-")) |err_name| {
                try d.diagnostics.set(err_name, .off);
            } else if (option(arg, "-W")) |err_name| {
                try d.diagnostics.set(err_name, .warning);
            } else if (option(arg, "-std=")) |standard| {
                d.comp.langopts.setStandard(standard) catch
                    try d.err("invalid standard '{s}'", .{arg});
            } else if (mem.eql(u8, arg, "-S") or mem.eql(u8, arg, "--assemble")) {
                d.only_preprocess_and_compile = true;
            } else if (mem.eql(u8, arg, "-target")) {
                i += 1;
                if (i >= args.len) {
                    try d.err("expected argument after -target", .{});
                    continue;
                }
                d.raw_target_triple = args[i];
            } else if (option(arg, "--target=")) |triple| {
                d.raw_target_triple = triple;
            } else if (mem.eql(u8, arg, "--verbose-ast")) {
                d.verbose_ast = true;
            } else if (mem.eql(u8, arg, "--verbose-pp")) {
                d.verbose_pp = true;
            } else if (mem.eql(u8, arg, "--verbose-ir")) {
                d.verbose_ir = true;
            } else if (mem.eql(u8, arg, "--verbose-linker-args")) {
                d.verbose_linker_args = true;
            } else if (mem.eql(u8, arg, "-C") or mem.eql(u8, arg, "--comments")) {
                d.comp.langopts.preserve_comments = true;
                comment_arg = arg;
            } else if (mem.eql(u8, arg, "-CC") or mem.eql(u8, arg, "--comments-in-macros")) {
                d.comp.langopts.preserve_comments = true;
                d.comp.langopts.preserve_comments_in_macros = true;
                comment_arg = arg;
            } else if (option(arg, "-fuse-ld=")) |linker_name| {
                d.use_linker = linker_name;
            } else if (mem.eql(u8, arg, "-fuse-ld=")) {
                d.use_linker = null;
            } else if (option(arg, "--ld-path=")) |linker_path| {
                d.linker_path = linker_path;
            } else if (mem.eql(u8, arg, "-r")) {
                d.relocatable = true;
            } else if (mem.eql(u8, arg, "-shared")) {
                d.shared = true;
            } else if (mem.eql(u8, arg, "-shared-libgcc")) {
                d.shared_libgcc = true;
            } else if (mem.eql(u8, arg, "-static")) {
                d.static = true;
            } else if (mem.eql(u8, arg, "-static-libgcc")) {
                d.static_libgcc = true;
            } else if (mem.eql(u8, arg, "-static-pie")) {
                d.static_pie = true;
            } else if (mem.eql(u8, arg, "-pie")) {
                d.pie = true;
            } else if (mem.eql(u8, arg, "-no-pie") or mem.eql(u8, arg, "-nopie")) {
                d.pie = false;
            } else if (mem.eql(u8, arg, "-rdynamic")) {
                d.rdynamic = true;
            } else if (mem.eql(u8, arg, "-s")) {
                d.strip = true;
            } else if (mem.eql(u8, arg, "-nodefaultlibs")) {
                d.nodefaultlibs = true;
            } else if (mem.eql(u8, arg, "-nolibc")) {
                d.nolibc = true;
            } else if (mem.eql(u8, arg, "-nobuiltininc")) {
                d.nobuiltininc = true;
            } else if (mem.eql(u8, arg, "-resource-dir")) {
                i += 1;
                if (i >= args.len) {
                    try d.err("expected argument after -resource-dir", .{});
                    continue;
                }
                d.resource_dir = args[i];
            } else if (mem.eql(u8, arg, "-nostdinc") or mem.eql(u8, arg, "--no-standard-includes")) {
                d.nostdinc = true;
            } else if (mem.eql(u8, arg, "-nostdlibinc")) {
                d.nostdlibinc = true;
            } else if (mem.eql(u8, arg, "-nostdlib")) {
                d.nostdlib = true;
            } else if (mem.eql(u8, arg, "-nostartfiles")) {
                d.nostartfiles = true;
            } else if (option(arg, "--unwindlib=")) |unwindlib| {
                const valid_unwindlibs: [5][]const u8 = .{ "", "none", "platform", "libunwind", "libgcc" };
                for (valid_unwindlibs) |name| {
                    if (mem.eql(u8, name, unwindlib)) {
                        d.unwindlib = unwindlib;
                        break;
                    }
                } else {
                    try d.err("invalid unwind library name  '{s}'", .{unwindlib});
                }
            } else {
                try d.warn("unknown argument '{s}'", .{arg});
            }
        } else if (std.mem.endsWith(u8, arg, ".o") or std.mem.endsWith(u8, arg, ".obj")) {
            try d.link_objects.append(d.comp.gpa, arg);
        } else {
            const source = d.addSource(arg) catch |er| {
                return d.fatal("unable to add source file '{s}': {s}", .{ arg, errorDescription(er) });
            };
            try d.inputs.append(d.comp.gpa, source);
        }
    }
    if (d.raw_target_triple) |triple| triple: {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch {
            try d.err("invalid target '{s}'", .{triple});
            d.raw_target_triple = null;
            break :triple;
        };
        const target = std.zig.system.resolveTargetQuery(query) catch |e| {
            return d.fatal("unable to resolve target: {s}", .{errorDescription(e)});
        };
        d.comp.target = target;
        d.comp.langopts.setEmulatedCompiler(target_util.systemCompiler(target));
        switch (d.comp.langopts.emulate) {
            .clang => try d.diagnostics.set("clang", .off),
            .gcc => try d.diagnostics.set("gnu", .off),
            .msvc => try d.diagnostics.set("microsoft", .off),
        }
    }
    if (d.comp.langopts.preserve_comments and !d.only_preprocess) {
        return d.fatal("invalid argument '{s}' only allowed with '-E'", .{comment_arg});
    }
    if (hosted) |is_hosted| {
        if (is_hosted) {
            if (d.comp.target.os.tag == .freestanding) {
                return d.fatal("Cannot use freestanding target with `-fhosted`", .{});
            }
        } else {
            d.comp.target.os.tag = .freestanding;
        }
    }
    const version = GCCVersion.parse(gnuc_version);
    if (version.major == -1) {
        return d.fatal("invalid value '{0s}' in '-fgnuc-version={0s}'", .{gnuc_version});
    }
    d.comp.langopts.gnuc_version = version.toUnsigned();
    const pic_level, const is_pie = try d.getPICMode(pic_arg);
    d.comp.code_gen_options.pic_level = pic_level;
    d.comp.code_gen_options.is_pie = is_pie;
    if (declspec_attrs) |some| d.comp.langopts.declspec_attrs = some;
    if (ms_extensions) |some| d.comp.langopts.setMSExtensions(some);
    return false;
}

fn option(arg: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, name) and arg.len > name.len) {
        return arg[name.len..];
    }
    return null;
}

fn addSource(d: *Driver, path: []const u8) !Source {
    if (mem.eql(u8, "-", path)) {
        const stdin = std.io.getStdIn().reader();
        const input = try stdin.readAllAlloc(d.comp.gpa, std.math.maxInt(u32));
        defer d.comp.gpa.free(input);
        return d.comp.addSourceFromBuffer("<stdin>", input);
    }
    return d.comp.addSourceFromPath(path);
}

pub fn err(d: *Driver, fmt: []const u8, args: anytype) Compilation.Error!void {
    var sf = std.heap.stackFallback(1024, d.comp.gpa);
    var buf = std.ArrayList(u8).init(sf.get());
    defer buf.deinit();

    try Diagnostics.formatArgs(buf.writer(), fmt, args);
    try d.diagnostics.add(.{ .kind = .@"error", .text = buf.items, .location = null });
}

pub fn warn(d: *Driver, fmt: []const u8, args: anytype) Compilation.Error!void {
    var sf = std.heap.stackFallback(1024, d.comp.gpa);
    var buf = std.ArrayList(u8).init(sf.get());
    defer buf.deinit();

    try Diagnostics.formatArgs(buf.writer(), fmt, args);
    try d.diagnostics.add(.{ .kind = .warning, .text = buf.items, .location = null });
}

pub fn unsupportedOptionForTarget(d: *Driver, target: std.Target, opt: []const u8) Compilation.Error!void {
    try d.err(
        "unsupported option '{s}' for target '{s}-{s}-{s}'",
        .{ opt, @tagName(target.cpu.arch), @tagName(target.os.tag), @tagName(target.abi) },
    );
}

pub fn fatal(d: *Driver, comptime fmt: []const u8, args: anytype) error{ FatalError, OutOfMemory } {
    var sf = std.heap.stackFallback(1024, d.comp.gpa);
    var buf = std.ArrayList(u8).init(sf.get());
    defer buf.deinit();

    try Diagnostics.formatArgs(buf.writer(), fmt, args);
    try d.diagnostics.add(.{ .kind = .@"fatal error", .text = buf.items, .location = null });
    unreachable;
}

pub fn printDiagnosticsStats(d: *Driver) void {
    const warnings = d.diagnostics.warnings;
    const errors = d.diagnostics.errors;

    const w_s: []const u8 = if (warnings == 1) "" else "s";
    const e_s: []const u8 = if (errors == 1) "" else "s";
    if (errors != 0 and warnings != 0) {
        std.debug.print("{d} warning{s} and {d} error{s} generated.\n", .{ warnings, w_s, errors, e_s });
    } else if (warnings != 0) {
        std.debug.print("{d} warning{s} generated.\n", .{ warnings, w_s });
    } else if (errors != 0) {
        std.debug.print("{d} error{s} generated.\n", .{ errors, e_s });
    }
}

pub fn detectConfig(d: *Driver, file: std.fs.File) std.io.tty.Config {
    if (d.color == true) return .escape_codes;
    if (d.color == false) return .no_color;

    if (file.supportsAnsiEscapeCodes()) return .escape_codes;
    if (@import("builtin").os.tag == .windows and file.isTty()) {
        var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (std.os.windows.kernel32.GetConsoleScreenBufferInfo(file.handle, &info) != std.os.windows.TRUE) {
            return .no_color;
        }
        return .{ .windows_api = .{
            .handle = file.handle,
            .reset_attributes = info.wAttributes,
        } };
    }

    return .no_color;
}

pub fn errorDescription(e: anyerror) []const u8 {
    return switch (e) {
        error.OutOfMemory => "ran out of memory",
        error.FileNotFound => "file not found",
        error.IsDir => "is a directory",
        error.NotDir => "is not a directory",
        error.NotOpenForReading => "file is not open for reading",
        error.NotOpenForWriting => "file is not open for writing",
        error.InvalidUtf8 => "path is not valid UTF-8",
        error.InvalidWtf8 => "path is not valid WTF-8",
        error.FileBusy => "file is busy",
        error.NameTooLong => "file name is too long",
        error.AccessDenied => "access denied",
        error.FileTooBig => "file is too big",
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "ran out of file descriptors",
        error.SystemResources => "ran out of system resources",
        error.FatalError => "a fatal error occurred",
        error.Unexpected => "an unexpected error occurred",
        else => @errorName(e),
    };
}

/// The entry point of the Aro compiler.
/// **MAY call `exit` if `fast_exit` is set.**
pub fn main(d: *Driver, tc: *Toolchain, args: []const []const u8, comptime fast_exit: bool, asm_gen_fn: ?AsmCodeGenFn) Compilation.Error!void {
    var macro_buf = std.ArrayList(u8).init(d.comp.gpa);
    defer macro_buf.deinit();

    const std_out = std.io.getStdOut().writer();
    if (try parseArgs(d, std_out, macro_buf.writer(), args)) return;

    const linking = !(d.only_preprocess or d.only_syntax or d.only_compile or d.only_preprocess_and_compile);

    if (d.inputs.items.len == 0) {
        return d.fatal("no input files", .{});
    } else if (d.inputs.items.len != 1 and d.output_name != null and !linking) {
        return d.fatal("cannot specify -o when generating multiple output files", .{});
    }

    if (!linking) for (d.link_objects.items) |obj| {
        try d.err("{s}: linker input file unused because linking not done", .{obj});
    };

    tc.discover() catch |er| switch (er) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyMultilibs => return d.fatal("found more than one multilib with the same priority", .{}),
    };
    tc.defineSystemIncludes() catch |er| switch (er) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AroIncludeNotFound => return d.fatal("unable to find Aro builtin headers", .{}),
    };

    const user_macros = d.comp.addSourceFromBuffer("<command line>", macro_buf.items) catch |er| switch (er) {
        error.StreamTooLong => return d.fatal("user provided macro source exceeded max size", .{}),
        else => |e| return e,
    };
    const builtin_macros = d.comp.generateBuiltinMacros(d.system_defines) catch |er| switch (er) {
        error.StreamTooLong => return d.fatal("builtin macro source exceeded max size", .{}),
        else => |e| return e,
    };
    if (fast_exit and d.inputs.items.len == 1) {
        try d.processSource(tc, d.inputs.items[0], builtin_macros, user_macros, fast_exit, asm_gen_fn);
        unreachable;
    }

    for (d.inputs.items) |source| {
        try d.processSource(tc, source, builtin_macros, user_macros, fast_exit, asm_gen_fn);
    }
    if (d.diagnostics.errors != 0) {
        if (fast_exit) d.exitWithCleanup(1);
        return;
    }
    if (linking) {
        try d.invokeLinker(tc, fast_exit);
    }
    if (fast_exit) std.process.exit(0);
}

fn getRandomFilename(d: *Driver, buf: *[std.fs.max_name_bytes]u8, extension: []const u8) ![]const u8 {
    const random_bytes_count = 12;
    const sub_path_len = comptime std.fs.base64_encoder.calcSize(random_bytes_count);

    var random_bytes: [random_bytes_count]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var random_name: [sub_path_len]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&random_name, &random_bytes);

    const fmt_template = "/tmp/{s}{s}";
    const fmt_args = .{
        random_name,
        extension,
    };
    return std.fmt.bufPrint(buf, fmt_template, fmt_args) catch return d.fatal("Filename too long for filesystem: " ++ fmt_template, fmt_args);
}

/// If it's used, buf will either hold a filename or `/tmp/<12 random bytes with base-64 encoding>.<extension>`
/// both of which should fit into max_name_bytes for all systems
fn getOutFileName(d: *Driver, source: Source, buf: *[std.fs.max_name_bytes]u8) ![]const u8 {
    if (d.only_compile or d.only_preprocess_and_compile) {
        const fmt_template = "{s}{s}";
        const fmt_args = .{
            std.fs.path.stem(source.path),
            if (d.only_preprocess_and_compile) ".s" else d.comp.target.ofmt.fileExt(d.comp.target.cpu.arch),
        };
        return d.output_name orelse
            std.fmt.bufPrint(buf, fmt_template, fmt_args) catch return d.fatal("Filename too long for filesystem: " ++ fmt_template, fmt_args);
    }

    return d.getRandomFilename(buf, d.comp.target.ofmt.fileExt(d.comp.target.cpu.arch));
}

fn invokeAssembler(d: *Driver, tc: *Toolchain, input_path: []const u8, output_path: []const u8) !void {
    var assembler_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const assembler_path = try tc.getAssemblerPath(&assembler_path_buf);
    const argv = [_][]const u8{ assembler_path, input_path, "-o", output_path };

    var child = std.process.Child.init(&argv, d.comp.gpa);
    // TODO handle better
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |er| {
        return d.fatal("unable to spawn linker: {s}", .{errorDescription(er)});
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            const e = d.fatal("assembler exited with an error code", .{});
            return e;
        },
        else => {
            const e = d.fatal("assembler crashed", .{});
            return e;
        },
    }
}

fn processSource(
    d: *Driver,
    tc: *Toolchain,
    source: Source,
    builtin: Source,
    user_macros: Source,
    comptime fast_exit: bool,
    asm_gen_fn: ?AsmCodeGenFn,
) !void {
    d.comp.generated_buf.items.len = 0;
    const prev_total = d.diagnostics.errors;

    var pp = try Preprocessor.initDefault(d.comp);
    defer pp.deinit();

    if (d.comp.langopts.ms_extensions) {
        d.comp.ms_cwd_source_id = source.id;
    }
    const dump_mode = d.debug_dump_letters.getPreprocessorDumpMode();
    if (d.verbose_pp) pp.verbose = true;
    if (d.only_preprocess) {
        pp.preserve_whitespace = true;
        if (d.line_commands) {
            pp.linemarkers = if (d.use_line_directives) .line_directives else .numeric_directives;
        }
        switch (dump_mode) {
            .macros_and_result, .macro_names_and_result => pp.store_macro_tokens = true,
            .result_only, .macros_only => {},
        }
    }

    try pp.preprocessSources(&.{ source, builtin, user_macros });

    if (d.only_preprocess) {
        d.printDiagnosticsStats();

        if (d.diagnostics.errors != prev_total) {
            if (fast_exit) std.process.exit(1); // Not linking, no need for cleanup.
            return;
        }

        const file = if (d.output_name) |some|
            d.comp.cwd.createFile(some, .{}) catch |er|
                return d.fatal("unable to create output file '{s}': {s}", .{ some, errorDescription(er) })
        else
            std.io.getStdOut();
        defer if (d.output_name != null) file.close();

        var buf_w = std.io.bufferedWriter(file.writer());

        pp.prettyPrintTokens(buf_w.writer(), dump_mode) catch |er|
            return d.fatal("unable to write result: {s}", .{errorDescription(er)});

        buf_w.flush() catch |er|
            return d.fatal("unable to write result: {s}", .{errorDescription(er)});
        if (fast_exit) std.process.exit(0); // Not linking, no need for cleanup.
        return;
    }

    var tree = try pp.parse();
    defer tree.deinit();

    if (d.verbose_ast) {
        const stdout = std.io.getStdOut();
        var buf_writer = std.io.bufferedWriter(stdout.writer());
        tree.dump(d.detectConfig(stdout), buf_writer.writer()) catch {};
        buf_writer.flush() catch {};
    }

    d.printDiagnosticsStats();

    if (d.diagnostics.errors != prev_total) {
        if (fast_exit) d.exitWithCleanup(1);
        return; // do not compile if there were errors
    }

    if (d.only_syntax) {
        if (fast_exit) std.process.exit(0); // Not linking, no need for cleanup.
        return;
    }

    if (d.comp.target.ofmt != .elf or d.comp.target.cpu.arch != .x86_64) {
        return d.fatal(
            "unsupported target {s}-{s}-{s}, currently only x86-64 elf is supported",
            .{ @tagName(d.comp.target.cpu.arch), @tagName(d.comp.target.os.tag), @tagName(d.comp.target.abi) },
        );
    }

    var name_buf: [std.fs.max_name_bytes]u8 = undefined;
    const out_file_name = try d.getOutFileName(source, &name_buf);

    if (d.use_assembly_backend) {
        const asm_fn = asm_gen_fn orelse return d.fatal(
            "Assembly codegen not supported",
            .{},
        );

        const assembly = try asm_fn(d.comp.target, &tree);
        defer assembly.deinit(d.comp.gpa);

        if (d.only_preprocess_and_compile) {
            const out_file = d.comp.cwd.createFile(out_file_name, .{}) catch |er|
                return d.fatal("unable to create output file '{s}': {s}", .{ out_file_name, errorDescription(er) });
            defer out_file.close();

            assembly.writeToFile(out_file) catch |er|
                return d.fatal("unable to write to output file '{s}': {s}", .{ out_file_name, errorDescription(er) });
            if (fast_exit) std.process.exit(0); // Not linking, no need for cleanup.
            return;
        }

        // write to assembly_out_file_name
        // then assemble to out_file_name
        var assembly_name_buf: [std.fs.max_name_bytes]u8 = undefined;
        const assembly_out_file_name = try d.getRandomFilename(&assembly_name_buf, ".s");
        const out_file = d.comp.cwd.createFile(assembly_out_file_name, .{}) catch |er|
            return d.fatal("unable to create output file '{s}': {s}", .{ assembly_out_file_name, errorDescription(er) });
        defer out_file.close();
        assembly.writeToFile(out_file) catch |er|
            return d.fatal("unable to write to output file '{s}': {s}", .{ assembly_out_file_name, errorDescription(er) });
        try d.invokeAssembler(tc, assembly_out_file_name, out_file_name);
        if (d.only_compile) {
            if (fast_exit) std.process.exit(0); // Not linking, no need for cleanup.
            return;
        }
    } else {
        var ir = try tree.genIr();
        defer ir.deinit(d.comp.gpa);

        if (d.verbose_ir) {
            const stdout = std.io.getStdOut();
            var buf_writer = std.io.bufferedWriter(stdout.writer());
            ir.dump(d.comp.gpa, d.detectConfig(stdout), buf_writer.writer()) catch {};
            buf_writer.flush() catch {};
        }

        var render_errors: Ir.Renderer.ErrorList = .{};
        defer {
            for (render_errors.values()) |msg| d.comp.gpa.free(msg);
            render_errors.deinit(d.comp.gpa);
        }

        var obj = ir.render(d.comp.gpa, d.comp.target, &render_errors) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LowerFail => {
                return d.fatal(
                    "unable to render Ir to machine code: {s}",
                    .{render_errors.values()[0]},
                );
            },
        };
        defer obj.deinit();

        const out_file = d.comp.cwd.createFile(out_file_name, .{}) catch |er|
            return d.fatal("unable to create output file '{s}': {s}", .{ out_file_name, errorDescription(er) });
        defer out_file.close();

        obj.finish(out_file) catch |er|
            return d.fatal("could not output to object file '{s}': {s}", .{ out_file_name, errorDescription(er) });
    }

    if (d.only_compile or d.only_preprocess_and_compile) {
        if (fast_exit) std.process.exit(0); // Not linking, no need for cleanup.
        return;
    }
    try d.link_objects.ensureUnusedCapacity(d.comp.gpa, 1);
    d.link_objects.appendAssumeCapacity(try d.comp.gpa.dupe(u8, out_file_name));
    d.temp_file_count += 1;
    if (fast_exit) {
        try d.invokeLinker(tc, fast_exit);
    }
}

fn dumpLinkerArgs(items: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    for (items, 0..) |item, i| {
        if (i > 0) try stdout.writeByte(' ');
        try stdout.print("\"{}\"", .{std.zig.fmtEscapes(item)});
    }
    try stdout.writeByte('\n');
}

/// The entry point of the Aro compiler.
/// **MAY call `exit` if `fast_exit` is set.**
pub fn invokeLinker(d: *Driver, tc: *Toolchain, comptime fast_exit: bool) Compilation.Error!void {
    var argv = std.ArrayList([]const u8).init(d.comp.gpa);
    defer argv.deinit();

    var linker_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const linker_path = try tc.getLinkerPath(&linker_path_buf);
    try argv.append(linker_path);

    try tc.buildLinkerArgs(&argv);

    if (d.verbose_linker_args) {
        dumpLinkerArgs(argv.items) catch |er| {
            return d.fatal("unable to dump linker args: {s}", .{errorDescription(er)});
        };
    }
    var child = std.process.Child.init(argv.items, d.comp.gpa);
    // TODO handle better
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |er| {
        return d.fatal("unable to spawn linker: {s}", .{errorDescription(er)});
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            const e = d.fatal("linker exited with an error code", .{});
            if (fast_exit) d.exitWithCleanup(code);
            return e;
        },
        else => {
            const e = d.fatal("linker crashed", .{});
            if (fast_exit) d.exitWithCleanup(1);
            return e;
        },
    }
    if (fast_exit) d.exitWithCleanup(0);
}

fn exitWithCleanup(d: *Driver, code: u8) noreturn {
    for (d.link_objects.items[d.link_objects.items.len - d.temp_file_count ..]) |obj| {
        std.fs.deleteFileAbsolute(obj) catch {};
    }
    std.process.exit(code);
}

/// Parses the various -fpic/-fPIC/-fpie/-fPIE arguments.
/// Then, smooshes them together with platform defaults, to decide whether
/// this compile should be using PIC mode or not.
/// Returns a tuple of ( backend.CodeGenOptions.PicLevel, IsPIE).
pub fn getPICMode(d: *Driver, lastpic: []const u8) Compilation.Error!struct { backend.CodeGenOptions.PicLevel, bool } {
    const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

    const target = d.comp.target;
    const linker = d.use_linker orelse @import("system_defaults").linker;
    const is_bfd_linker = eqlIgnoreCase(linker, "bfd");

    const is_pie_default = switch (target_util.isPIEDefault(target)) {
        .yes => true,
        .no => false,
        .depends_on_linker => if (is_bfd_linker)
            target.cpu.arch == .x86_64 // CrossWindows
        else
            false, //MSVC
    };
    const is_pic_default = switch (target_util.isPICdefault(target)) {
        .yes => true,
        .no => false,
        .depends_on_linker => if (is_bfd_linker)
            target.cpu.arch == .x86_64
        else
            (target.cpu.arch == .x86_64 or target.cpu.arch == .aarch64),
    };

    var pie: bool = is_pie_default;
    var pic: bool = pie or is_pic_default;
    // The Darwin/MachO default to use PIC does not apply when using -static.
    if (target.ofmt == .macho and d.static) {
        pic, pie = .{ false, false };
    }
    var is_piclevel_two = pic;

    const kernel_or_kext: bool = d.mkernel or d.apple_kext;

    // Android-specific defaults for PIC/PIE
    if (target.abi.isAndroid()) {
        switch (target.cpu.arch) {
            .arm,
            .armeb,
            .thumb,
            .thumbeb,
            .aarch64,
            .mips,
            .mipsel,
            .mips64,
            .mips64el,
            => pic = true, // "-fpic"

            .x86, .x86_64 => {
                pic = true; // "-fPIC"
                is_piclevel_two = true;
            },
            else => {},
        }
    }

    // OHOS-specific defaults for PIC/PIE
    if (target.abi == .ohos and target.cpu.arch == .aarch64)
        pic = true;

    // OpenBSD-specific defaults for PIE
    if (target.os.tag == .openbsd) {
        switch (target.cpu.arch) {
            .arm, .aarch64, .mips64, .mips64el, .x86, .x86_64 => is_piclevel_two = false, // "-fpie"
            .powerpc, .sparc64 => is_piclevel_two = true, // "-fPIE"
            else => {},
        }
    }

    // The last argument relating to either PIC or PIE wins, and no
    // other argument is used. If the last argument is any flavor of the
    // '-fno-...' arguments, both PIC and PIE are disabled. Any PIE
    // option implicitly enables PIC at the same level.
    if (target.os.tag == .windows and
        !target_util.isCygwinMinGW(target) and
        (eqlIgnoreCase(lastpic, "-fpic") or eqlIgnoreCase(lastpic, "-fpie"))) // -fpic/-fPIC, -fpie/-fPIE
    {
        try d.unsupportedOptionForTarget(target, lastpic);
        if (target.cpu.arch == .x86_64)
            return .{ .two, false };
        return .{ .none, false };
    }

    // Check whether the tool chain trumps the PIC-ness decision. If the PIC-ness
    // is forced, then neither PIC nor PIE flags will have no effect.
    const forced = switch (target_util.isPICDefaultForced(target)) {
        .yes => true,
        .no => false,
        .depends_on_linker => if (is_bfd_linker) target.cpu.arch == .x86_64 else target.cpu.arch == .aarch64 or target.cpu.arch == .x86_64,
    };
    if (!forced) {
        // -fpic/-fPIC, -fpie/-fPIE
        if (eqlIgnoreCase(lastpic, "-fpic") or eqlIgnoreCase(lastpic, "-fpie")) {
            pie = eqlIgnoreCase(lastpic, "-fpie");
            pic = pie or eqlIgnoreCase(lastpic, "-fpic");
            is_piclevel_two = mem.eql(u8, lastpic, "-fPIE") or mem.eql(u8, lastpic, "-fPIC");
        } else {
            pic, pie = .{ false, false };
            if (target_util.isPS(target)) {
                if (d.cmodel != .kernel) {
                    pic = true;
                    try d.warn(
                        "option '{s}' was ignored by the {s} toolchain, using '-fPIC'",
                        .{ lastpic, if (target.os.tag == .ps4) "PS4" else "PS5" },
                    );
                }
            }
        }
    }

    if (pic and (target.os.tag.isDarwin() or target_util.isPS(target))) {
        is_piclevel_two = is_piclevel_two or is_pic_default;
    }

    // This kernel flags are a trump-card: they will disable PIC/PIE
    // generation, independent of the argument order.
    if (kernel_or_kext and
        (!(target.os.tag != .ios) or (target.os.isAtLeast(.ios, .{ .major = 6, .minor = 0, .patch = 0 }) orelse false)) and
        !(target.os.tag != .watchos) and
        !(target.os.tag != .driverkit))
    {
        pie, pic = .{ false, false };
    }

    if (d.dynamic_nopic == true) {
        if (!target.os.tag.isDarwin()) {
            try d.unsupportedOptionForTarget(target, "-mdynamic-no-pic");
        }
        pic = is_pic_default or forced;
        return .{ if (pic) .two else .none, false };
    }

    const embedded_pi_supported = target.cpu.arch.isArm();
    if (!embedded_pi_supported) {
        if (d.ropi) try d.unsupportedOptionForTarget(target, "-fropi");
        if (d.rwpi) try d.unsupportedOptionForTarget(target, "-frwpi");
    }

    // ROPI and RWPI are not compatible with PIC or PIE.
    if ((d.ropi or d.rwpi) and (pic or pie)) {
        try d.err("embedded and GOT-based position independence are incompatible", .{});
    }

    if (target.cpu.arch.isMIPS()) {
        // When targeting the N64 ABI, PIC is the default, except in the case
        // when the -mno-abicalls option is used. In that case we exit
        // at next check regardless of PIC being set below.
        // TODO: implement incomplete!!
        if (target.cpu.arch.isMIPS64())
            pic = true;

        // When targettng MIPS with -mno-abicalls, it's always static.
        if (d.mabicalls == false)
            return .{ .none, false };

        // Unlike other architectures, MIPS, even with -fPIC/-mxgot/multigot,
        // does not use PIC level 2 for historical reasons.
        is_piclevel_two = false;
    }

    if (pic) return .{ if (is_piclevel_two) .two else .one, pie };
    return .{ .none, false };
}
