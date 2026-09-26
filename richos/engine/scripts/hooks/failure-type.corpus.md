# Failure-type trigger corpus (synthetic)

The trigger rule is the operator's own, in his words: whenever he mentions the
words "type" and "failure" close to each other. The trigger predicate
implements it literally: an inflection of *type* (type, types, typed, typing)
and an inflection of *failure* (failure, failures), in either order, at most
six words apart, in HIS text only.

**These lines are synthetic.** This repository is public, so no line of any
private transcript is copied here. Each line reproduces the SHAPE of a real
message (word order, capitals, punctuation, distance between the two words)
without its content. The real messages are kept in the private record, and
`failure-type.test.sh` case FT05 runs them through the same predicate when
that record is on the machine, and prints NOT RUN when it is not.

The measurement those shapes come from, taken 2026-09-26 over every transcript
on the machine where the rule was written: 2,645 messages whose origin is the
operator; 36 contain both words, and in all 36 the two words are one or two
words apart. The window of six is therefore headroom for phrasings not yet
seen, not a fitted number: every window from two upward selects the same 36.

Format: `+ ` must trigger, `- ` must not. The suite reads every such line.

## Positive: his shapes

+ what type of failure is that?
+ what type of failure was that now??
+ Is this type of failure already recorded?
+ when will this failure and this type of failure be documented?
+ is this failure and failure type documented already?
+ are these failure types documented already?
+ when will this failure type be documented?
+ is this covered by one of the documented failure types already?
+ WHAT MUST HAPPEN WHENEVER I MENTION THE WORDS "TYPE" AND "FAILURE" CLOSE TO EACH OTHER???
+ AND IS ***THIS*** TYPE OF FAILURE ALREADY RECORDED???
+ "a quoted sentence from a report": what type of failure is that? hygiene, probably.
+ record all of it. Your failures, other failures, types of failures, everything.
+ the heading for each failure type must start with the word Type and a number
+ "it wrote without a message": what would be the title for this failure type?
+ why does NOT every failure type there start with a heading that names it????

## Positive: inflections, order and distance

+ which failure is this, by type?
+ Type of failure, please.
+ typed it as a failure in the log
+ the failures of this type keep coming back
+ this is the same type of recurring failure as before
+ type one two three four five failure
+ failure one two three four five type
+ failure-type
+ what type-of-failure is it

## Negative: one word only, or too far apart

- that's not the first time I'm seeing this type of thing.
- Why do you keep using the wrong type of English?
- Knowing that the transcription failed after the call ended is unacceptable.
- where is the record of the failures today after my order?
- the build failed again and the test is failing
- TypeScript compile error in the failure-free path
- type one two three four five six failure
- failure one two three four five six type
- a prototype is not a failure test, it is a typology question
- he typed nothing and nothing failed
