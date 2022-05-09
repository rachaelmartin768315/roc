#[macro_use]
extern crate const_format;

use build::BuiltFile;
use bumpalo::Bump;
use clap::{Arg, ArgMatches, Command};
use roc_build::link::LinkType;
use roc_error_macros::user_error;
use roc_load::{LoadingProblem, Threading};
use roc_mono::ir::OptLevel;
use std::env;
use std::ffi::OsStr;
use std::io;
use std::path::Path;
use std::process;
use target_lexicon::BinaryFormat;
use target_lexicon::{
    Architecture, Environment, OperatingSystem, Triple, Vendor, X86_32Architecture,
};

pub mod build;
mod format;
pub use format::format;

pub const CMD_BUILD: &str = "build";
pub const CMD_RUN: &str = "run";
pub const CMD_REPL: &str = "repl";
pub const CMD_EDIT: &str = "edit";
pub const CMD_DOCS: &str = "docs";
pub const CMD_CHECK: &str = "check";
pub const CMD_VERSION: &str = "version";
pub const CMD_FORMAT: &str = "format";

pub const FLAG_DEBUG: &str = "debug";
pub const FLAG_DEV: &str = "dev";
pub const FLAG_OPTIMIZE: &str = "optimize";
pub const FLAG_MAX_THREADS: &str = "max-threads";
pub const FLAG_OPT_SIZE: &str = "opt-size";
pub const FLAG_LIB: &str = "lib";
pub const FLAG_NO_LINK: &str = "no-link";
pub const FLAG_TARGET: &str = "target";
pub const FLAG_TIME: &str = "time";
pub const FLAG_LINKER: &str = "linker";
pub const FLAG_PRECOMPILED: &str = "precompiled-host";
pub const FLAG_VALGRIND: &str = "valgrind";
pub const FLAG_CHECK: &str = "check";
pub const ROC_FILE: &str = "ROC_FILE";
pub const ROC_DIR: &str = "ROC_DIR";
pub const DIRECTORY_OR_FILES: &str = "DIRECTORY_OR_FILES";
pub const ARGS_FOR_APP: &str = "ARGS_FOR_APP";

const VERSION: &str = include_str!("../../version.txt");

pub fn build_app<'a>() -> Command<'a> {
    let flag_optimize = Arg::new(FLAG_OPTIMIZE)
        .long(FLAG_OPTIMIZE)
        .help("Optimize the compiled program to run faster. (Optimization takes time to complete.)")
        .requires(ROC_FILE)
        .required(false);

    let flag_max_threads = Arg::new(FLAG_MAX_THREADS)
        .long(FLAG_MAX_THREADS)
        .help("Limit the number of threads (and hence cores) used during compilation.")
        .requires(ROC_FILE)
        .takes_value(true)
        .validator(|s| s.parse::<usize>())
        .required(false);

    let flag_opt_size = Arg::new(FLAG_OPT_SIZE)
        .long(FLAG_OPT_SIZE)
        .help("Optimize the compiled program to have a small binary size. (Optimization takes time to complete.)")
        .required(false);

    let flag_dev = Arg::new(FLAG_DEV)
        .long(FLAG_DEV)
        .help("Make compilation finish as soon as possible, at the expense of runtime performance.")
        .required(false);

    let flag_debug = Arg::new(FLAG_DEBUG)
        .long(FLAG_DEBUG)
        .help("Store LLVM debug information in the generated program.")
        .requires(ROC_FILE)
        .required(false);

    let flag_valgrind = Arg::new(FLAG_VALGRIND)
        .long(FLAG_VALGRIND)
        .help("Some assembly instructions are not supported by valgrind, this flag prevents those from being output when building the host.")
        .required(false);

    let flag_time = Arg::new(FLAG_TIME)
        .long(FLAG_TIME)
        .help("Prints detailed compilation time information.")
        .required(false);

    let flag_linker = Arg::new(FLAG_LINKER)
        .long(FLAG_LINKER)
        .help("Sets which linker to use. The surgical linker is enabled by default only when building for wasm32 or x86_64 Linux, because those are the only targets it currently supports. Otherwise the legacy linker is used by default.")
        .possible_values(["surgical", "legacy"])
        .required(false);

    let flag_precompiled = Arg::new(FLAG_PRECOMPILED)
        .long(FLAG_PRECOMPILED)
        .help("Assumes the host has been precompiled and skips recompiling the host. (Enabled by default when using `roc build` with a --target other than `--target host`)")
        .possible_values(["true", "false"])
        .required(false);

    let roc_file_to_run = Arg::new(ROC_FILE)
        .help("The .roc file of an app to run")
        .allow_invalid_utf8(true);

    let args_for_app = Arg::new(ARGS_FOR_APP)
        .help("Arguments to pass into the app being run")
        .requires(ROC_FILE)
        .allow_invalid_utf8(true)
        .multiple_values(true);

    let app = Command::new("roc")
        .version(concatcp!(VERSION, "\n"))
        .about("Runs the given .roc file, if there are no compilation errors.\nUse one of the SUBCOMMANDS below to do something else!")
        .subcommand(Command::new(CMD_BUILD)
            .about("Build a binary from the given .roc file, but don't run it")
            .arg(flag_optimize.clone())
            .arg(flag_max_threads.clone())
            .arg(flag_opt_size.clone())
            .arg(flag_dev.clone())
            .arg(flag_debug.clone())
            .arg(flag_time.clone())
            .arg(flag_linker.clone())
            .arg(flag_precompiled.clone())
            .arg(flag_valgrind.clone())
            .arg(
                Arg::new(FLAG_TARGET)
                    .long(FLAG_TARGET)
                    .help("Choose a different target")
                    .default_value(Target::default().as_str())
                    .possible_values(Target::OPTIONS)
                    .required(false),
            )
            .arg(
                Arg::new(FLAG_LIB)
                    .long(FLAG_LIB)
                    .help("Build a C library instead of an executable.")
                    .required(false),
            )
            .arg(
                Arg::new(FLAG_NO_LINK)
                    .long(FLAG_NO_LINK)
                    .help("Does not link. Instead just outputs the `.o` file")
                    .required(false),
            )
            .arg(
                Arg::new(ROC_FILE)
                    .help("The .roc file to build")
                    .allow_invalid_utf8(true)
                    .required(true),
            )
        )
        .subcommand(Command::new(CMD_REPL)
            .about("Launch the interactive Read Eval Print Loop (REPL)")
        )
        .subcommand(Command::new(CMD_RUN)
            .about("Run a .roc file even if it has build errors")
            .arg(flag_optimize.clone())
            .arg(flag_max_threads.clone())
            .arg(flag_opt_size.clone())
            .arg(flag_dev.clone())
            .arg(flag_debug.clone())
            .arg(flag_time.clone())
            .arg(flag_linker.clone())
            .arg(flag_precompiled.clone())
            .arg(flag_valgrind.clone())
            .arg(roc_file_to_run.clone().required(true))
            .arg(args_for_app.clone())
        )
        .subcommand(Command::new(CMD_FORMAT)
            .about("Format a .roc file using standard Roc formatting")
            .arg(
                Arg::new(DIRECTORY_OR_FILES)
                    .index(1)
                    .multiple_values(true)
                    .required(false)
                    .allow_invalid_utf8(true))
            .arg(
                Arg::new(FLAG_CHECK)
                    .long(FLAG_CHECK)
                    .help("Checks that specified files are formatted. If formatting is needed, it will return a non-zero exit code.")
                    .required(false),
            )
        )
        .subcommand(Command::new(CMD_VERSION)
            .about(concatcp!("Print the Roc compiler’s version, which is currently ", VERSION)))
        .subcommand(Command::new(CMD_CHECK)
            .about("Check the code for problems, but doesn’t build or run it")
            .arg(flag_time.clone())
            .arg(flag_max_threads.clone())
            .arg(
                Arg::new(ROC_FILE)
                    .help("The .roc file of an app to check")
                    .allow_invalid_utf8(true)
                    .required(true),
            )
            )
        .subcommand(
            Command::new(CMD_DOCS)
                .about("Generate documentation for Roc modules (Work In Progress)")
                .arg(Arg::new(DIRECTORY_OR_FILES)
                    .multiple_values(true)
                    .required(false)
                    .help("The directory or files to build documentation for")
                    .allow_invalid_utf8(true)
                )
        )
        .trailing_var_arg(true)
        .arg(flag_optimize)
            .arg(flag_max_threads.clone())
        .arg(flag_opt_size)
        .arg(flag_dev)
        .arg(flag_debug)
        .arg(flag_time)
        .arg(flag_linker)
        .arg(flag_precompiled)
        .arg(flag_valgrind)
        .arg(roc_file_to_run.required(false))
        .arg(args_for_app);

    if cfg!(feature = "editor") {
        app.subcommand(
            Command::new(CMD_EDIT)
                .about("Launch the Roc editor (Work In Progress)")
                .arg(
                    Arg::new(DIRECTORY_OR_FILES)
                        .multiple_values(true)
                        .required(false)
                        .help("(optional) The directory or files to open on launch."),
                ),
        )
    } else {
        app
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum BuildConfig {
    BuildOnly,
    BuildAndRun,
    BuildAndRunIfNoErrors,
}

pub enum FormatMode {
    Format,
    CheckOnly,
}

pub fn build(
    matches: &ArgMatches,
    config: BuildConfig,
    triple: Triple,
    link_type: LinkType,
) -> io::Result<i32> {
    use build::build_file;
    use BuildConfig::*;

    let arena = Bump::new();
    let filename = matches.value_of_os(ROC_FILE).unwrap();

    let original_cwd = std::env::current_dir()?;
    let opt_level = match (
        matches.is_present(FLAG_OPTIMIZE),
        matches.is_present(FLAG_OPT_SIZE),
        matches.is_present(FLAG_DEV),
    ) {
        (true, false, false) => OptLevel::Optimize,
        (false, true, false) => OptLevel::Size,
        (false, false, true) => OptLevel::Development,
        (false, false, false) => OptLevel::Normal,
        _ => user_error!("build can be only one of `--dev`, `--optimize`, or `--opt-size`"),
    };
    let emit_debug_info = matches.is_present(FLAG_DEBUG);
    let emit_timings = matches.is_present(FLAG_TIME);

    let threading = match matches
        .value_of(FLAG_MAX_THREADS)
        .and_then(|s| s.parse::<usize>().ok())
    {
        None => Threading::AllAvailable,
        Some(0) => user_error!("cannot build with at most 0 threads"),
        Some(1) => Threading::Single,
        Some(n) => Threading::AtMost(n),
    };

    // Use surgical linking when supported, or when explicitly requested with --linker surgical
    let surgically_link = if matches.is_present(FLAG_LINKER) {
        matches.value_of(FLAG_LINKER) == Some("surgical")
    } else {
        roc_linker::supported(&link_type, &triple)
    };

    let precompiled = if matches.is_present(FLAG_PRECOMPILED) {
        matches.value_of(FLAG_PRECOMPILED) == Some("true")
    } else {
        // When compiling for a different target, default to assuming a precompiled host.
        // Otherwise compilation would most likely fail!
        triple != Triple::host()
    };
    let path = Path::new(filename);

    // Spawn the root task
    let path = path.canonicalize().unwrap_or_else(|err| {
        use io::ErrorKind::*;

        match err.kind() {
            NotFound => {
                match path.to_str() {
                    Some(path_str) => println!("File not found: {}", path_str),
                    None => println!("Malformed file path : {:?}", path),
                }

                process::exit(1);
            }
            _ => {
                todo!("TODO Gracefully handle opening {:?} - {:?}", path, err);
            }
        }
    });

    let src_dir = path.parent().unwrap().canonicalize().unwrap();
    let target_valgrind = matches.is_present(FLAG_VALGRIND);
    let res_binary_path = build_file(
        &arena,
        &triple,
        src_dir,
        path,
        opt_level,
        emit_debug_info,
        emit_timings,
        link_type,
        surgically_link,
        precompiled,
        target_valgrind,
        threading,
    );

    match res_binary_path {
        Ok(BuiltFile {
            binary_path,
            problems,
            total_time,
        }) => {
            match config {
                BuildOnly => {
                    // If possible, report the generated executable name relative to the current dir.
                    let generated_filename = binary_path
                        .strip_prefix(env::current_dir().unwrap())
                        .unwrap_or(&binary_path);

                    // No need to waste time freeing this memory,
                    // since the process is about to exit anyway.
                    std::mem::forget(arena);

                    println!(
                        "\x1B[{}m{}\x1B[39m {} and \x1B[{}m{}\x1B[39m {} found in {} ms while successfully building:\n\n    {}",
                        if problems.errors == 0 {
                            32 // green
                        } else {
                            33 // yellow
                        },
                        problems.errors,
                        if problems.errors == 1 {
                            "error"
                        } else {
                            "errors"
                        },
                        if problems.warnings == 0 {
                            32 // green
                        } else {
                            33 // yellow
                        },
                        problems.warnings,
                        if problems.warnings == 1 {
                            "warning"
                        } else {
                            "warnings"
                        },
                        total_time.as_millis(),
                        generated_filename.to_str().unwrap()
                    );

                    // Return a nonzero exit code if there were problems
                    Ok(problems.exit_code())
                }
                BuildAndRun => {
                    if problems.errors > 0 || problems.warnings > 0 {
                        println!(
                            "\x1B[{}m{}\x1B[39m {} and \x1B[{}m{}\x1B[39m {} found in {} ms.\n\nRunning program anyway…\n\n\x1B[36m{}\x1B[39m",
                            if problems.errors == 0 {
                                32 // green
                            } else {
                                33 // yellow
                            },
                            problems.errors,
                            if problems.errors == 1 {
                                "error"
                            } else {
                                "errors"
                            },
                            if problems.warnings == 0 {
                                32 // green
                            } else {
                                33 // yellow
                            },
                            problems.warnings,
                            if problems.warnings == 1 {
                                "warning"
                            } else {
                                "warnings"
                            },
                            total_time.as_millis(),
                            "─".repeat(80)
                        );
                    }

                    let args = matches.values_of_os(ARGS_FOR_APP).unwrap_or_default();

                    roc_run(arena, &original_cwd, triple, args, &binary_path)
                }
                BuildAndRunIfNoErrors => {
                    if problems.errors == 0 {
                        if problems.warnings > 0 {
                            println!(
                                "\x1B[32m0\x1B[39m errors and \x1B[33m{}\x1B[39m {} found in {} ms.\n\nRunning program…\n\n\x1B[36m{}\x1B[39m",
                                problems.warnings,
                                if problems.warnings == 1 {
                                    "warning"
                                } else {
                                    "warnings"
                                },
                                total_time.as_millis(),
                                "─".repeat(80)
                            );
                        }

                        let args = matches.values_of_os(ARGS_FOR_APP).unwrap_or_default();

                        roc_run(arena, &original_cwd, triple, args, &binary_path)
                    } else {
                        println!(
                            "\x1B[{}m{}\x1B[39m {} and \x1B[{}m{}\x1B[39m {} found in {} ms.\n\nYou can run the program anyway with: \x1B[32mroc run {}\x1B[39m",
                            if problems.errors == 0 {
                                32 // green
                            } else {
                                33 // yellow
                            },
                            problems.errors,
                            if problems.errors == 1 {
                                "error"
                            } else {
                                "errors"
                            },
                            if problems.warnings == 0 {
                                32 // green
                            } else {
                                33 // yellow
                            },
                            problems.warnings,
                            if problems.warnings == 1 {
                                "warning"
                            } else {
                                "warnings"
                            },
                            total_time.as_millis(),
                            filename.to_string_lossy()
                        );

                        Ok(problems.exit_code())
                    }
                }
            }
        }
        Err(LoadingProblem::FormattedReport(report)) => {
            print!("{}", report);

            Ok(1)
        }
        Err(other) => {
            panic!("build_file failed with error:\n{:?}", other);
        }
    }
}

fn roc_run<'a, I: IntoIterator<Item = &'a OsStr>>(
    arena: Bump, // This should be passed an owned value, not a reference, so we can usefully mem::forget it!
    cwd: &Path,
    triple: Triple,
    args: I,
    binary_path: &Path,
) -> io::Result<i32> {
    match triple.architecture {
        Architecture::Wasm32 => {
            // If possible, report the generated executable name relative to the current dir.
            let generated_filename = binary_path
                .strip_prefix(env::current_dir().unwrap())
                .unwrap_or(binary_path);

            // No need to waste time freeing this memory,
            // since the process is about to exit anyway.
            std::mem::forget(arena);

            if cfg!(target_family = "unix") {
                use std::os::unix::ffi::OsStrExt;

                run_with_wasmer(
                    generated_filename,
                    args.into_iter().map(|os_str| os_str.as_bytes()),
                );
            } else {
                run_with_wasmer(
                    generated_filename,
                    args.into_iter().map(|os_str| {
                        os_str.to_str().expect(
                            "Roc does not currently support passing non-UTF8 arguments to Wasmer.",
                        )
                    }),
                );
            }

            Ok(0)
        }
        _ => {
            if cfg!(target_family = "unix") {
                roc_run_unix(cwd, args, binary_path)
            } else {
                roc_run_non_unix(arena, cwd, args, binary_path)
            }
        }
    }
}

fn roc_run_unix<I: IntoIterator<Item = S>, S: AsRef<OsStr>>(
    cwd: &Path,
    args: I,
    binary_path: &Path,
) -> io::Result<i32> {
    use std::os::unix::process::CommandExt;

    let mut cmd = std::process::Command::new(&binary_path);

    // Forward all the arguments after the .roc file argument
    // to the new process. This way, you can do things like:
    //
    // roc app.roc foo bar baz
    //
    // ...and have it so that app.roc will receive only `foo`,
    // `bar`, and `baz` as its arguments.
    for arg in args {
        cmd.arg(arg);
    }

    // This is much faster than spawning a subprocess if we're on a UNIX system!
    let err = cmd.current_dir(cwd).exec();

    // If exec actually returned, it was definitely an error! (Otherwise,
    // this process would have been replaced by the other one, and we'd
    // never actually reach this line of code.)
    Err(err)
}

fn roc_run_non_unix<I: IntoIterator<Item = S>, S: AsRef<OsStr>>(
    _arena: Bump, // This should be passed an owned value, not a reference, so we can usefully mem::forget it!
    _cwd: &Path,
    _args: I,
    _binary_path: &Path,
) -> io::Result<i32> {
    todo!("TODO support running roc programs on non-UNIX targets");
    // let mut cmd = std::process::Command::new(&binary_path);

    // // Run the compiled app
    // let exit_status = cmd
    //     .spawn()
    //     .unwrap_or_else(|err| panic!("Failed to run app after building it: {:?}", err))
    //     .wait()
    //     .expect("TODO gracefully handle block_on failing when `roc` spawns a subprocess for the compiled app");

    // // `roc [FILE]` exits with the same status code as the app it ran.
    // //
    // // If you want to know whether there were compilation problems
    // // via status code, use either `roc build` or `roc check` instead!
    // match exit_status.code() {
    //     Some(code) => Ok(code),
    //     None => {
    //         todo!("TODO gracefully handle the `roc [FILE]` subprocess terminating with a signal.");
    //     }
    // }
}

#[cfg(feature = "run-wasm32")]
fn run_with_wasmer<I: Iterator<Item = S>, S: AsRef<[u8]>>(wasm_path: &std::path::Path, args: I) {
    use wasmer::{Instance, Module, Store};

    let store = Store::default();
    let module = Module::from_file(&store, &wasm_path).unwrap();

    // First, we create the `WasiEnv`
    use wasmer_wasi::WasiState;
    let mut wasi_env = WasiState::new("hello").args(args).finalize().unwrap();

    // Then, we get the import object related to our WASI
    // and attach it to the Wasm instance.
    let import_object = wasi_env.import_object(&module).unwrap();

    let instance = Instance::new(&module, &import_object).unwrap();

    let start = instance.exports.get_function("_start").unwrap();

    use wasmer_wasi::WasiError;
    match start.call(&[]) {
        Ok(_) => {}
        Err(e) => match e.downcast::<WasiError>() {
            Ok(WasiError::Exit(0)) => {
                // we run the `_start` function, so exit(0) is expected
            }
            other => panic!("Wasmer error: {:?}", other),
        },
    }
}

#[cfg(not(feature = "run-wasm32"))]
fn run_with_wasmer<I: Iterator<Item = S>, S: AsRef<[u8]>>(_wasm_path: &std::path::Path, _args: I) {
    println!("Running wasm files is not supported on this target.");
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum Target {
    System,
    Linux32,
    Linux64,
    Wasm32,
}

impl Default for Target {
    fn default() -> Self {
        Target::System
    }
}

impl Target {
    const fn as_str(&self) -> &'static str {
        use Target::*;

        match self {
            System => "system",
            Linux32 => "linux32",
            Linux64 => "linux64",
            Wasm32 => "wasm32",
        }
    }

    /// NOTE keep up to date!
    const OPTIONS: &'static [&'static str] = &[
        Target::System.as_str(),
        Target::Linux32.as_str(),
        Target::Linux64.as_str(),
        Target::Wasm32.as_str(),
    ];

    pub fn to_triple(self) -> Triple {
        use Target::*;

        match self {
            System => Triple::host(),
            Linux32 => Triple {
                architecture: Architecture::X86_32(X86_32Architecture::I386),
                vendor: Vendor::Unknown,
                operating_system: OperatingSystem::Linux,
                environment: Environment::Musl,
                binary_format: BinaryFormat::Elf,
            },
            Linux64 => Triple {
                architecture: Architecture::X86_64,
                vendor: Vendor::Unknown,
                operating_system: OperatingSystem::Linux,
                environment: Environment::Musl,
                binary_format: BinaryFormat::Elf,
            },
            Wasm32 => Triple {
                architecture: Architecture::Wasm32,
                vendor: Vendor::Unknown,
                operating_system: OperatingSystem::Unknown,
                environment: Environment::Unknown,
                binary_format: BinaryFormat::Wasm,
            },
        }
    }
}

impl From<&Target> for Triple {
    fn from(target: &Target) -> Self {
        target.to_triple()
    }
}

impl std::fmt::Display for Target {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl std::str::FromStr for Target {
    type Err = String;

    fn from_str(string: &str) -> Result<Self, Self::Err> {
        match string {
            "system" => Ok(Target::System),
            "linux32" => Ok(Target::Linux32),
            "linux64" => Ok(Target::Linux64),
            "wasm32" => Ok(Target::Wasm32),
            _ => Err(format!("Roc does not know how to compile to {}", string)),
        }
    }
}
