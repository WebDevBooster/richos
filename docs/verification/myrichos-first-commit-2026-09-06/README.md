# `~/myrichos` — the first commit, and the probes that prove its check can fail

Mark (backend) · 2026-09-06 · repo `richos`, branch `mark-opus-mrf1`

The central-folder design's §6 "smallest useful first commit": the folder, the six
`companies/<id>/company.md` files, the six copied guard fragments. **It changes no behavior** —
nothing in `app/**` reads any of it — so the design says it "needs no verification beyond the
files being there."

That is true of the folder. It is **not** true of `check-myrichos.sh`, which is the thing making
§1.3's pointers *checked* pointers. A check that has only ever been observed passing is not
evidence of anything, and this project's standing rule is that a negative test needs a positive
probe. So the check was made to fail, three ways, on purpose.

## The tree, as built

```
$ tools/myrichos/build-myrichos.sh
myrichos: /Users/alex/myrichos
created: 21 file(s)   kept existing: 0 file(s)

$ find ~/myrichos -type f | sort
README.md
me/doctrine.source.md
me/identity.config
companies/deeply/company.md
companies/deeply/guards/SOURCES
companies/deeply/guards/deeply-design-brief-gate.sh
companies/deeply/guards/settings.json
companies/femcboost/company.md
companies/femcboost/guards/SOURCES
companies/femcboost/guards/ecs-session-start.sh
companies/femcboost/guards/ecs-stop.sh
companies/femcboost/guards/ecs-task-completed.sh
companies/femcboost/guards/ecs-teammate-idle.sh
companies/femcboost/guards/ecs-user-prompt-submit.sh
companies/femcboost/guards/settings.json
companies/gpt-exporter/company.md
companies/gpt-exporter/guards/settings.json
companies/prospects/company.md
companies/prospects/guards/settings.json
companies/richos/company.md
companies/richos/guards/settings.json
companies/webinar-booster/company.md
companies/webinar-booster/guards/settings.json
```

23 files. Six `company.md`, six `settings.json` fragments, six copied hook scripts, two `SOURCES`
drift manifests, the person layer's pointer and identity file, and the README addressed to him.
`companies/<id>/team/`, `companies/<id>/memory/`, `registry/` and `inbox/` exist and are empty —
§6 lists their contents as separate items, and a directory the design names is a target for the
next step, where an absent one is a surprise for it.

## The probes

| # | What was broken | Result |
|---|---|---|
| P1 | Appended a line to the **copy** of `ecs-stop.sh` | `FAIL femcboost/ecs-stop.sh: the COPY here was edited and no longer matches the original`, **exit 1** |
| P2 | Pointed `canonical:` at `/Users/alex/RichOS/corpus/inner-doctrine.md` (a real dangling path on this machine) | `FAIL me/doctrine.source.md points at a target that does not exist`, **exit 1** |
| P3 | Target restored, `canonical-sha256:` falsified to all zeros | `FAIL the person-layer template CHANGED since this pointer was written`, both digests printed, **exit 1** |
| P4 | Re-ran the builder over the finished folder | `created: 0 file(s)   kept existing: 21 file(s)` — nothing clobbered |
| P5 | `MYRICHOS_ROOT=<scratch>` build, then `grep -rl /Users/alex/myrichos <scratch>` | **no matches** — no seed file hard-codes the parent |

**P3 is the one that matters** and it is why the pointer records a digest rather than just a
path. P2 alone would be an existence check, and an existence check passes happily on a file whose
contents have been replaced. P3 is this repository's own freshness contract — identity or refuse —
applied to a pointer.

**P5 is the evidence for §8's open question 1.** `~/myrichos` versus `~/ab/myrichos` is
unresolved, is the CEO's call, and he has not been asked. It is honored as literally one line:
`MYRICHOS_ROOT` in `build-myrichos.sh`. Building at a different root produced a correct tree with
no trace of the default anywhere in it.

On the real folder, after all of the above, `check-myrichos.sh` exits 0.

## Why P1 and P3 will not stay theoretical

The copies in `guards/` are deliberate — §5.2 copies at step 2 and deletes the originals at step
6, three steps later, so that no window has zero enforcement. For the length of that window six
scripts exist twice.

Two copies of a guard with no drift check is not a hypothetical failure on this machine, it is a
measured one: `claude-orchestration-kit` ships an isolation guard at 404 lines against the
engine's current 1090. So `build-myrichos.sh` writes `guards/SOURCES` with each copy's origin and
SHA-256, and the checker compares three things — the recorded digest, the live original, and the
copy — and says which one moved. P1 exercises the third; the second is what would catch the kit's
failure mode.

> **Nothing in `claude-orchestration-kit` is read, written, deleted or consolidated by any of
> this.** The design document's rows about deleting its 13 hooks are struck by the correction at
> the top of that same document: the kit is a standalone product other people copy into their own
> repositories, its hooks are the thing being shipped, and on an adopter's machine the engine
> plugin does not exist at all. It is cited above only as measured evidence for why copies get
> checked.

## The dangling links this is modeled on

P2's path is not invented. Measured 2026-09-06:

```
$ ls -l "$HOME/Library/Application Support/RichOS/" | grep corpus
corpus.RAY-101-RUN-A               -> /Users/alex/RichOS/corpus
corpus.RAY-101-RUN-B               -> /Users/alex/RichOS/corpus
corpus.RAY-101-RUN-C               -> /Users/alex/RichOS/corpus
corpus.RAY-STRANGER-RUN-2026-09-04 -> /Users/alex/RichOS/corpus

$ ls -d /Users/alex/RichOS
ls: /Users/alex/RichOS: No such file or directory     # exit 1
```

Four pointers, dangling since 2026-09-04, and nothing has ever said so. §1.3's rule is that a
pointer whose target is missing is an error rather than a fallback; an error nothing computes is
a wish, and `check-myrichos.sh` is the thing that computes it.

**These four links are not cleaned up here.** That is §5.2 step 9 and it is out of this commit's
scope.
