app "echo"
    packages { pf: "https://github.com/roc-lang/basic-cli/releases/download/0.7.0/bkGby8jb0tmZYsy2hg1E_B2QrCgcSTxdUlHtETwm5m4.tar.br" }
    imports [pf.Stdin, pf.Stdout, pf.Task.{ Task }]
    provides [main] to pf

main : Task {} I32
main =
    _ <- Task.await (Stdout.line "🗣  Shout into this cave and hear the echo! 👂👂👂")

    Task.loop {} tick

tick : {} -> Task [Step {}, Done {}] *
tick = \{} ->
    shout <- Task.await Stdin.line

    when shout is
        Input s -> Stdout.line (echo s) |> Task.map Step
        End -> Stdout.line (echo "Received end of input (EOF).") |> Task.map Done

echo : Str -> Str
echo = \shout ->
    silence = \length ->
        spaceInUtf8 = 32

        List.repeat spaceInUtf8 length

    shout
    |> Str.toUtf8
    |> List.mapWithIndex
        (\_, i ->
            length = (List.len (Str.toUtf8 shout) - i)
            phrase = (List.split (Str.toUtf8 shout) length).before

            List.concat (silence (if i == 0 then 2 * length else length)) phrase)
    |> List.join
    |> Str.fromUtf8
    |> Result.withDefault ""
