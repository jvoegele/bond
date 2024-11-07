# About

Bond provides support for contract programming (also known as
"Design By Contract") for Elixir.

The primary goal for Bond is to provide the most feature-complete and thoroughly
documented Design By Contract library for Elixir, with a concise and flexible
syntax for specifying contracts.

Current and planned features include:

- [x] Function preconditions with `@pre`
- [x] Function postconditions with `@post`
- [x] "old" expressions in postconditions
- [x] "check" expressions for arbitrary assertions within a function body
- [x] Predicates (such as `implies?` and `xor`) for use in assertions
- [x] Detailed assertion failure reporting
- [x] Incorporation of preconditions and postconditions into @doc for function
- [ ] Conditional compilation of contracts per environment
- [ ] More detailed assertion failure reporting, including color coding à la `ExUnit`
- [ ] Invariants for structs and/or stateful processes (if possible)
