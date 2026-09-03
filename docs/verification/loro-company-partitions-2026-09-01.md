# Moved to the private record — 2026-09-03/04

**The finding, which is the part a stranger needs:** a corpus with no company partitions gives
every entity the same memory, and neither the lane map nor the cross-entity guard can see that
this is wrong — an unpartitioned corpus has nothing to narrow and nothing to refuse, so both
report success while one company's record is handed to all of them. Machinery being correct is
not the same as machinery having anything to act on.

**RESOLVED 2026-09-01.** The layout learned partitions, every company was provisioned, and every
record was filed by the rule that a record about one venture is that venture's and a rule
spanning every company is the operator's. Re-run against the partitioned corpus, the
cross-entity guard REFUSES by name the exact slice that previously crossed. The behavior is
covered by tests in `app/crates/richos-core/` and by `tools/richos-service/`'s suite.

**The measurement itself is in the private record**, at
`docs/verification/loro-company-partitions-2026-09-01.md`. It stays there because it is made
almost entirely of the operator's private material: his companies by name, the size and contents
of his private record, a path into it, a ruling of his quoted, and a rendered slice of his own
company memory on a live commercial topic. None of that is needed to understand the defect, and
publishing it would be exactly what `.publication-boundary` exists to prevent.

The rule that decides what stays here and what moves: `engine/CLAUDE.md.template`, *"Writing for
a Repository That PUBLISHES — the same doctrine, in two modes"*.
