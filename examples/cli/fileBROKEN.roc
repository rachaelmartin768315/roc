app "file-io"
    packages { pf: "https://github.com/roc-lang/basic-cli/releases/download/0.10.0/vNe6s9hWzoTZtFmNkvEICPErI9ptji_ySjicO6CkucY.tar.br" }
    imports [
        pf.Stdout,
        pf.Task.{ Task },
        pf.File,
        pf.Path,
        pf.Env,
        pf.Dir,
    ]
    provides [main] to pf

main : Task {} [Exit I32 Str]_
main =
    path = Path.fromStr "out.txt"

    task =
        cwd = Env.cwd!
        Stdout.line! "cwd: $(Path.display cwd)"
        dirEntries = Dir.list! cwd
        contentsStr = Str.joinWith (List.map dirEntries Path.display) "\n    "
        Stdout.line! "Directory contents:\n    $(contentsStr)\n"
        Stdout.line! "Writing a string to out.txt"
        File.writeUtf8! path "a string!"
        contents = File.readUtf8! path
        Stdout.line! "I read the file back. Its contents: \"$(contents)\""

    when Task.result! task is
        Ok {} -> Stdout.line! "Successfully wrote a string to out.txt"
        Err err ->
            msg =
                when err is
                    FileWriteErr _ PermissionDenied -> "PermissionDenied"
                    FileWriteErr _ Unsupported -> "Unsupported"
                    FileWriteErr _ (Unrecognized _ other) -> other
                    FileReadErr _ _ -> "Error reading file"
                    _ -> "Uh oh, there was an error!"

            Task.err (Exit 1 msg)
