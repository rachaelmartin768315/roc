platform "folkertdev/foo"
    requires { Model } { main : Effect {} }
    exposes []
    packages {}
    imports []
    provides [ mainForHost ]

mainForHost : { init : ({} -> Model) as Init, update : (Model, Str -> Model) as Update, view : (Model -> Str) as View }
mainForHost = main
