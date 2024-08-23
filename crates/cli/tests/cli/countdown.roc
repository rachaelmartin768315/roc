app [main] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.14.0/dC5ceT962N_4jmoyoffVdphJ_4GlW3YMhAPyGPr-nU0.tar.br" }

import pf.Stdin
import pf.Stdout
import pf.Task exposing [Task, loop]

main =
    Stdout.line! "\nLet's count down from 3 together - all you have to do is press <ENTER>."
    _ = Stdin.line!
    loop 3 tick

tick = \n ->
    if n == 0 then
        Stdout.line! "🎉 SURPRISE! Happy Birthday! 🎂"
        Task.ok (Done {})
    else
        Stdout.line! (n |> Num.toStr |> \s -> "$(s)...")
        _ = Stdin.line!
        Task.ok (Step (n - 1))
