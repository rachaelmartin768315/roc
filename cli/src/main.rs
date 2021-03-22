use roc_cli::{build, docs, build_app, repl, DIRECTORY_OR_FILES};
use std::io;
use std::path::{Path, PathBuf};
use target_lexicon::Triple;

fn main() -> io::Result<()> {
    let matches = build_app().get_matches();

    match matches.subcommand_name() {
        None => roc_editor::launch(&[]),
        Some("build") => build(
            &Triple::host(),
            matches.subcommand_matches("build").unwrap(),
            false,
        ),
        Some("run") => build(
            &Triple::host(),
            matches.subcommand_matches("run").unwrap(),
            true,
        ),
        Some("repl") => repl::main(),
        Some("edit") => {
            match matches
                .subcommand_matches("edit")
                .unwrap()
                .values_of_os(DIRECTORY_OR_FILES)
            {
                None => roc_editor::launch(&[]),
                Some(values) => {
                    let paths = values
                        .map(|os_str| Path::new(os_str))
                        .collect::<Vec<&Path>>();

                    roc_editor::launch(&paths)
                }
            }
        }
        Some("docs") => {
            let values = matches
                .subcommand_matches("docs")
                .unwrap()
                .values_of_os(DIRECTORY_OR_FILES)
                .unwrap();

            let paths = values
                .map(|os_str| Path::new(os_str).to_path_buf())
                .collect::<Vec<PathBuf>>();

            docs(paths);

            Ok(())
        }
        _ => unreachable!(),
    }
}
