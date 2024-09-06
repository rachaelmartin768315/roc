app [main] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.15.0/SlwdbJ-3GR7uBWQo6zlmYWNYOxnvo8r6YABXD-45UOw.tar.br" }

import pf.Stdout
import "test-file.txt" as testFile : _ # the _ is optional

main =
    # Due to the functions we apply on testFile, it will be inferred as a List U8.
    testFile
        |> List.map Num.toU64
        |> List.sum
        |> Num.toStr
        |> Stdout.line!
