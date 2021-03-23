#[macro_use]
extern crate clap;

use bumpalo::Bump;
use clap::ArgMatches;
use clap::{App, Arg};
use roc_build::link::LinkType;
use roc_gen::llvm::build::OptLevel;
use roc_load::file::LoadingProblem;
use std::io;
use std::path::Path;
use std::process;
use std::process::Command;
use target_lexicon::Triple;

pub mod build;
pub mod repl;

pub static FLAG_DEBUG: &str = "debug";
pub static FLAG_OPTIMIZE: &str = "optimize";
pub static FLAG_ROC_FILE: &str = "ROC_FILE";
pub static DIRECTORY_OR_FILES: &str = "DIRECTORY_OR_FILES";

pub fn build_app<'a>() -> App<'a> {
    App::new("roc")
        .version(crate_version!())
        .subcommand(App::new("build")
            .about("Build a program")
            .arg(
                Arg::with_name(FLAG_ROC_FILE)
                    .help("The .roc file to build")
                    .required(true),
            )
            .arg(
                Arg::with_name(FLAG_OPTIMIZE)
                    .long(FLAG_OPTIMIZE)
                    .help("Optimize the compiled program to run faster. (Optimization takes time to complete.)")
                    .required(false),
            )
            .arg(
                Arg::with_name(FLAG_DEBUG)
                    .long(FLAG_DEBUG)
                    .help("Store LLVM debug information in the generated program")
                    .required(false),
            )
        )
        .subcommand(App::new("run")
            .about("Build and run a program")
            .arg(
                Arg::with_name(FLAG_ROC_FILE)
                    .help("The .roc file to build and run")
                    .required(true),
            )
            .arg(
                Arg::with_name(FLAG_OPTIMIZE)
                    .long(FLAG_OPTIMIZE)
                    .help("Optimize the compiled program to run faster. (Optimization takes time to complete.)")
                    .required(false),
            )
            .arg(
                Arg::with_name(FLAG_DEBUG)
                    .long(FLAG_DEBUG)
                    .help("Store LLVM debug information in the generated program")
                    .required(false),
            )
        )
        .subcommand(App::new("repl")
            .about("Launch the interactive Read Eval Print Loop (REPL)")
        )
        .subcommand(App::new("edit")
            .about("Launch the Roc editor")
            .arg(Arg::with_name(DIRECTORY_OR_FILES)
                .index(1)
                .multiple(true)
                .required(false)
                .help("(optional) The directory or files to open on launch.")
            )
        )
}

pub fn build(target: &Triple, matches: &ArgMatches, run_after_build: bool) -> io::Result<()> {
    let arena = Bump::new();
    let filename = matches.value_of(FLAG_ROC_FILE).unwrap();

    let opt_level = if matches.is_present(FLAG_OPTIMIZE) {
        OptLevel::Optimize
    } else {
        OptLevel::Normal
    };
    let emit_debug_info = matches.is_present(FLAG_DEBUG);

    let path = Path::new(filename).canonicalize().unwrap();
    let src_dir = path.parent().unwrap().canonicalize().unwrap();

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

    let res_binary_path = build::build_file(
        &arena,
        target,
        src_dir,
        path,
        opt_level,
        emit_debug_info,
        LinkType::Executable,
    );

    match res_binary_path {
        Ok(binary_path) => {
            if run_after_build {
                // Run the compiled app
                Command::new(binary_path)
                    .spawn()
                    .unwrap_or_else(|err| panic!("Failed to run app after building it: {:?}", err))
                    .wait()
                    .expect("TODO gracefully handle block_on failing");
            }
        }
        Err(LoadingProblem::FormattedReport(report)) => {
            print!("{}", report);
        }
        Err(other) => {
            panic!("build_file failed with error:\n{:?}", other);
        }
    }

    Ok(())
}
