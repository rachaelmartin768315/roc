# META
~~~ini
description=Nested heterogeneous lists
type=expr
~~~
# SOURCE
~~~roc
[[1, "hello"], [2, 3]]
~~~
# PROBLEMS
**INCOMPATIBLE LIST ELEMENTS**
The 1st and 2nd elements in this list have incompatible types:
**can_nested_heterogeneous_lists.md:1:3:1:13:**
```roc
[[1, "hello"], [2, 3]]
```
  ^^^^^^^^^^

The 1st element has this type:
    _Num(*)_

However, the 2nd element has this type:
    _Str_

All elements in a list must have compatible types.

**INCOMPATIBLE LIST ELEMENTS**
The 1st and 2nd elements in this list have incompatible types:
**can_nested_heterogeneous_lists.md:1:2:1:22:**
```roc
[[1, "hello"], [2, 3]]
```
 ^^^^^^^^^^^^^^^^^^^^

The 1st element has this type:
    _List(Error)_

However, the 2nd element has this type:
    _List(Num(*))_

All elements in a list must have compatible types.

# TOKENS
~~~zig
OpenSquare(1:1-1:2),OpenSquare(1:2-1:3),Int(1:3-1:4),Comma(1:4-1:5),StringStart(1:6-1:7),StringPart(1:7-1:12),StringEnd(1:12-1:13),CloseSquare(1:13-1:14),Comma(1:14-1:15),OpenSquare(1:16-1:17),Int(1:17-1:18),Comma(1:18-1:19),Int(1:20-1:21),CloseSquare(1:21-1:22),CloseSquare(1:22-1:23),EndOfFile(1:23-1:23),
~~~
# PARSE
~~~clojure
(e-list @1-1-1-23
	(e-list @1-2-1-14
		(e-int @1-3-1-4 (raw "1"))
		(e-string @1-6-1-13
			(e-string-part @1-7-1-12 (raw "hello"))))
	(e-list @1-16-1-22
		(e-int @1-17-1-18 (raw "2"))
		(e-int @1-20-1-21 (raw "3"))))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(e-list @1-1-1-23 (elem-var 75) (id 79)
	(elems
		(e-list @1-2-1-14 (elem-var 72)
			(elems
				(e-int @1-3-1-4 (value "1"))
				(e-string @1-6-1-13
					(e-literal @1-7-1-12 (string "hello")))))
		(e-list @1-16-1-22 (elem-var 76)
			(elems
				(e-int @1-17-1-18 (value "2"))
				(e-int @1-20-1-21 (value "3"))))))
~~~
# TYPES
~~~clojure
(expr (id 79) (type "List(Error)"))
~~~
