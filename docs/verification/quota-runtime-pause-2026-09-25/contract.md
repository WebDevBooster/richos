# Orchestrator pause message contract

The user narrowed this change to the message the orchestrator sends. There is no
process-control redesign and no change to subagent runtime or agent role files.

One standard body lives in `scripts/lib/pause_protocol.py`. Only its closed reason
and validated reset time vary. Manual CLI preparation, the quota watcher and the
desktop preparation tool all use that source. Both delivery paths validate the
whole body and summary before permitting SendMessage. They reject replacement,
appended or contradictory alias instructions. No forbidden-word blacklist is used:
"do not stop" is part of the approved message.

The acceptance regression is the incident's message containing "End any heavy run
you own" and "re-run what was cut off". That message must be refused by both paths.
A delivered request must not be presented as evidence of an observed pause.

The five-hour 93% rule, strictly-under-20-minute exception, five-minute polling
and separate 99% weekly reset trigger stay as implemented. No reset is redeemed.

Enforcement boundary: declared pause controls, legacy `pause-until:` messages,
pause wording and imperative hold wording are routed to exact payload validation.
This is not a claim that a word matcher can classify every possible natural-language
instruction. Ordinary work messages still exist. Rich is instructed to use the
fixed generator for every pause and never compose pause instructions itself.
