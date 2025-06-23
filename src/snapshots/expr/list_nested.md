# META
~~~ini
description=Nested list literals
type=expr
~~~
# SOURCE
~~~roc
[[1, 2], [3, 4], [5]]
~~~
# PROBLEMS
~~~txt
NIL
~~~
# TOKENS
~~~zig
OpenSquare(1:1-1:2),OpenSquare(1:2-1:3),Int(1:3-1:4),Comma(1:4-1:5),Int(1:6-1:7),CloseSquare(1:7-1:8),Comma(1:8-1:9),OpenSquare(1:10-1:11),Int(1:11-1:12),Comma(1:12-1:13),Int(1:14-1:15),CloseSquare(1:15-1:16),Comma(1:16-1:17),OpenSquare(1:18-1:19),Int(1:19-1:20),CloseSquare(1:20-1:21),CloseSquare(1:21-1:22),EndOfFile(1:22-1:22),
~~~
# PARSE
~~~clojure
(list (1:1-1:22)
	(list (1:2-1:8)
		(int (1:3-1:4) "1")
		(int (1:6-1:7) "2"))
	(list (1:10-1:16)
		(int (1:11-1:12) "3")
		(int (1:14-1:15) "4"))
	(list (1:18-1:21) (int (1:19-1:20) "5")))
~~~
# FORMATTED
~~~roc
NO CHANGE
~~~
# CANONICALIZE
~~~clojure
(e_list (1:1-1:22)
	(elem_var 33)
	(elems
		(e_list (1:2-1:8)
			(elem_var 18)
			(elems
				(e_int (1:3-1:4)
					(int_var 13)
					(precision_var 12)
					(literal "1")
					(value "TODO")
					(bound "u8"))
				(e_int (1:6-1:7)
					(int_var 16)
					(precision_var 15)
					(literal "2")
					(value "TODO")
					(bound "u8"))))
		(e_list (1:10-1:16)
			(elem_var 26)
			(elems
				(e_int (1:11-1:12)
					(int_var 21)
					(precision_var 20)
					(literal "3")
					(value "TODO")
					(bound "u8"))
				(e_int (1:14-1:15)
					(int_var 24)
					(precision_var 23)
					(literal "4")
					(value "TODO")
					(bound "u8"))))
		(e_list (1:18-1:21)
			(elem_var 31)
			(elems
				(e_int (1:19-1:20)
					(int_var 29)
					(precision_var 28)
					(literal "5")
					(value "TODO")
					(bound "u8"))))))
~~~
# TYPES
~~~clojure
(expr 34 (type "List(List(Num(Int(*))))"))
~~~