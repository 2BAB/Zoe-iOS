# Privacy and interaction boundaries

## Replay

- WebKit loads public pages directly. Page JavaScript and subresources are enabled, so websites can make their normal requests and observe the connection.
- Each run uses a new non-persistent website data store. Navigation shares that session without reusing the user's normal browser login.
- Semantic tasks run with the local Apple model. Replay does not send page evidence to Gemini or Private Cloud Compute.
- Workflows, source evidence, run logs and the latest result are stored locally under Application Support/Zoe.

## Building

The remote builder receives the goal, URL, page observations and execution previews. Local semantic trials and workflow verification return their outputs and token usage to the builder.

- Gemini requests go to Google under the API key's terms. The key stays in memory.
- Private Cloud Compute requests use Apple's configured service and require entitlement.
- Caller-supplied rebuild feedback is also sent to the chosen builder.

Build logs may contain page excerpts. The opt-in smoke driver saves workflows, results and logs in the chosen output directory. Review this data flow before using sensitive pages or sharing logs.

## Interactions

Reviewing and saving a workflow authorizes its query operations and allowed document hosts. Query operations may navigate, search, select filters, expand content or scroll. The builder is instructed to avoid purchases, reservations, account changes, sign-in and access-control bypasses.

This is not an absolute read-only sandbox. Arbitrary scripts and website JavaScript can have side effects. Host checks govern document navigation, not every subresource or DNS destination. Missing page structure and access challenges are errors rather than evidence of an empty result.

No analytics or third-party SDKs are included.
