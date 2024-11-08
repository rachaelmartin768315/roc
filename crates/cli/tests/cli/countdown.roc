app [main] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.16.0/O00IPk-Krg_diNS2dVWlI0ZQP794Vctxzv0ha96mK0E.tar.br" }

import pf.Stdin
import pf.Stdout

main =
    Stdout.line! "\nLet's count down from 3 together - all you have to do is press <ENTER>."
    _ = Stdin.line!
    Task.loop 3 tick

tick = \n ->
    if n == 0 then
        Stdout.line! "🎉 SURPRISE! Happy Birthday! 🎂"
        Task.ok (Done {})
    else
        Stdout.line! (n |> Num.toStr |> \s -> "$(s)...")
        _ = Stdin.line!
        Task.ok (Step (n - 1))
