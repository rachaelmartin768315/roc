interface Dep1
    exposes [three, str, Unit, Identity, one, two]
    imports []

import Dep3 exposing [foo]

one = 1

two = foo

three = 3.0

str = "string!"

Unit : [Unit]

Identity a : [Identity a]
