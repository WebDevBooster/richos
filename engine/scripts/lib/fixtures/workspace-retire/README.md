# Workspace retirement incident fixture

`pre-containment-remove-agent-worktree.sh.txt` is the exact RichOS helper from
`a20a6e8cc52d0cbbee0e287526b09844f8370ab1:engine/scripts/remove-agent-worktree.sh`,
the parent of the containment fix `1b84a1c`. It is first-party code governed by
the repository's AGPL-3.0-only license.

SHA-256: `8d9356388d7a88f53b194c821f3874689f691381ae08595adca041b3bc8dbcda`.

This historical helper is deliberately unsafe. It is non-executable test input,
not an installed helper. Row R1a copies it into a disposable sandbox to prove
that the malformed owner and container path can reproduce the original sibling
deletions. The current helper must refuse the same fixture without mutation.

Keeping exact bytes here lets shallow clones and adopted engine checkouts run
the negative control without RichOS history. The test checks the hash and fails
if the input is missing or modified.
