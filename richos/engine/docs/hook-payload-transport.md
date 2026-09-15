# Hook payload transport

Hook input and predicate output are unbounded document data. Pass them between
processes through stdin, a separate file descriptor or a temporary file. Do not
put an entire JSON payload, extracted message or command in an environment value
or command-line argument. Linux limits individual argument and environment
strings independently of the total argument budget. JSON escaping can cross that
limit even when the decoded command is small enough to execute.

For `python3 -c`, stdin is available for data. When stdin contains an inline Python
program, descriptor 3 can carry data with `3<<< "$PAYLOAD"`; the program reads it
with `json.load(os.fdopen(3))`. Bounded metadata such as store paths and event names
can still use environment variables. Here-strings append a newline, which JSON
parsers accept as trailing whitespace. Plain-text serializers must preserve their
existing trailing-newline behavior explicitly.

A blocking guard must distinguish a successful classification of an unrelated
operation from failure to run its classifier. Process execution failure returns
an explicit refusal, exit 2. The shared Git resolver emits an anchor only after
successful execution. A partial result from a failed resolver cannot authorize
checking a guessed repository. Notification hooks retain their existing
nonblocking malformed-event behavior; changing transport does not change policy.

Consumers must also read complete producer output. Under `pipefail`, an
early-exiting `head` or `grep -q` can turn a successful producer into SIGPIPE and
reverse a guard decision. Use consuming first-line selectors such as `sed -n
'1p'`, or a consuming predicate with output redirected to `/dev/null`.

The regressions exercise real hooks, temporary Git repositories and isolated
state stores. They cover long valid JSON, refusal and clean controls, retained
acknowledgements, durable lifecycle records and deliberate classifier execution
failures. Linux negative controls demonstrate the original failures; macOS tests
check that the transport remains portable. They run through automatic test
discovery, including `payload-transport.test.sh` and
`lifecycle-payload-transport.test.sh`.
