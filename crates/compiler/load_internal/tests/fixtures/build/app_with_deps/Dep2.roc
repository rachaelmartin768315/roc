interface Dep2
    exposes [one, two, blah]
    imports []

import Dep3Blah exposing [foo, bar]

one = 1

blah = foo

two = 2.0
