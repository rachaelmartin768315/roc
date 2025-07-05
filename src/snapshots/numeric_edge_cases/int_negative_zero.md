# META
~~~ini
description=Negative integer zero
type=expr
~~~
# SOURCE
~~~roc
-0
~~~
~~~
# EXPECTED
NIL
# PROBLEMS
NIL
# TOKENS
~~~zig
Int(1:1-1:3),Newline(1:1-1:1),
MalformedUnknownToken(2:1-2:2),MalformedUnknownToken(2:2-2:3),MalformedUnknownToken(2:3-2:4),EndOfFile(2:4-2:4),
~~~
# PARSE
~~~clojure
(e-int @1.1-1.3 (raw "-0"))
~~~
# FORMATTED
~~~roc
-0
~~~
# CANONICALIZE
~~~clojure
(e-int @1.1-1.3 (value "0"))
~~~
# TYPES
~~~clojure
(expr @1.1-1.3 (type "Num(*)"))
~~~
