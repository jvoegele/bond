# History

The ideas and philosophy of Design By Contract are, of course, not original to
Bond, having first been developed by Bertrand Meyer in the mid 1980s. Meyer's
work was itself based on earlier work in the field of formal specification and
verification, by Tony Hoare and others.

Nor is Bond the first or only attempt at bringing the ideas of contract
programming to Elixir.

## Prior art and related work

In 2016, Elba Sanchez Marquez presented at various conferences and in blog posts
the [elixir-contracts](https://github.com/epsanchezma/elixir-contracts) library,
which she collaboratively developed with Guillermo Iguaran. These conference
presentations and the `elixir-contracts` library represented a good introduction
to contract programming for the Elixir community. However, development of the
library ceased after a mere 10 commits to its GitHub repository.

In 2017, Dariusz Gawdzik created his
[ExContract](https://github.com/JDUnity/ex_contract) library, with contributions
from myself and others. This library took ideas from the `elixir-contracts`
library as a starting point and produced a more complete implementation and
thorough documentation. However, development of `ExContract`, too, halted in
2019 after 19 commits, and with
[one unmerged pull request](https://github.com/JDUnity/ex_contract/pull/4)
from [yours truly](https://github.com/jvoegele).

At ElixirConf 2019, Chris Keathley gave a talk titled
[Contracts for Building Reliable Systems](https://www.youtube.com/watch?v=tpo3JUyVIjQ),
which presented the ideas of Design By Contract using `ExContract` for
its examples, as well as the distinct but related idea of data specification
using his library [Norm](https://github.com/elixir-toniq/norm), which we'll come
back to shortly. (I happened to be in the audience for this talk and was pleased
to see that a library that I was actively contributing to at the time was being
presented to the Elixir community at large.) Shortly thereafter, Keathley
released his own library for Design By Contract in Elixir:
[Oath](https://github.com/keathley/oath). Oath supports the same basic notions
as earlier DbC libraries of having preconditions and postconditions attached to
functions, but does so using a different (and rather verbose) syntax based on
the popular [decorator](https://github.com/arjan/decorator) library. Oath was
the first Elixir contracts library that allowed for conditionally enabling
contracts on a per-environment basis, so that contracts could be compiled into
the code in dev and test environments, but disabled in production so that
there are no runtime costs associated with contracts. At the time of writing,
Oath is currently the most popular contracts library for Elixir, but like the
others before it, it has been largely unmaintained and development has ceased
as of April of 2021 (22 commits in this time).

## Raison d'être

After growing dissatisfied with the existing offerings for Design By Contract in
Elixir, I decided to create my own.

`ExContract` provided the most complete implementation and documentation, but
having tried and failed to revive development I gave up on this library.

Oath, even though it is not actively maintained, is reasonably complete and its
support for conditional compilation of contracts is an attractive feature.
However, its verbose syntax and dearth of documentation are both barriers to its
widespread adoption.

Enter [Bond](https://github.com/jvoegele/bond).

## Credits

The initial implementation was based partially on `ExContract`, or more
precisely, on my
[unmerged pull request](https://github.com/JDUnity/ex_contract/pull/4) to it.
The implementation of preconditions and postconditions as `@pre` and `@post`
module attributes is accomplished by selectively overriding Elixir's
`Kernel.@/1` macro, a technique discovered by studying the source code to
[Norm's @contract construct](https://github.com/elixir-toniq/norm/blob/be1c31bc33ae10723b3d4fe8b9b3a2ffce90b710/lib/norm/contract.ex#L57-L65).

## A note on data specification and validation

A closely related notion to contract programming is "data specification", an
idea that has become popular in the functional programming community via
[clojure.spec](https://clojure.org/about/spec). In Elixir, the de facto standard
for data specification and validation is the aforementioned
[Norm](https://github.com/elixir-toniq/norm) library from Chris Keathley, et al.
Although Bond does not currently support data specification, if there is ever
a demonstrated need for integrating Design By Contract with data specification,
Bond may be extended to support it, perhaps with a `Bond.Spec` module. In the
meantime, it is entirely possible to use Norm in conjunction with Bond.
