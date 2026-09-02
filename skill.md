---
name: corbado-observe
description: Integrate Corbado Observe into a frontend application to measure
  authentication flows like login, signup, recovery or enrollment. Use when adding
  Corbado Observe, authentication analytics or passkey/login funnel tracking
  to an app.
---

# Corbado Observe integration

Corbado Observe is fire-and-forget telemetry for authentication journeys. You map the
application's auth journeys onto Observe's taxonomy — flows, decisions, subflows — and a
backend classifier turns the event stream into funnels and analytics.

**Scope: this skill implements the Custom Events approach** — explicit Observe events
emitted from the application's own code at the semantically correct points, via
`@corbado/observe`. Corbado's other approach, **Autocapture**, observes browser signals
(WebAuthn ceremonies, selected network exchanges, navigation) without application
changes. The two can coexist in one project. Don't confuse the packages:
`@corbado/autocapture` is the low-level signal observers, not the tracker SDK this
skill uses. Everything below is custom-events instrumentation.

## System context: model for the classifier, not the event log

Raw events are only the transport. The classifier consumes each session's event stream and
produces the flows, decisions and subflow attempts that every aggregating dashboard is
built on. Raw events surface in the console for debugging individual users; classification
output is what carries the value. The classifier itself is not visible from the
integration so this skill encodes its core rules. Reason about every emission through
those rules, from the classifier's perspective, instead of judging how the raw series looks.

The classifier merges aggressively, so the client needs no defensive deduplication:

- A repeated `flow_started` for an already-open flow merges into it (latest `touchpoint`
  wins, tags accumulate).
- Consecutive `subflow_started` of the same subflow type fold into one attempt (a
  different, known spec type starts a new attempt).
- Decisions behave differently on purpose: every rendered decision surfaces as its own
  occurrence. A later re-emission — same or changed options — closes the open occurrence
  as incomplete and starts a new one; a revisited checkpoint is signal, not noise.

So for flows and subflows, re-emitting on re-render is safe by design; for decisions,
emit per *semantic* render and dedup identical consecutive offers by value, so framework
re-renders don't mint phantom occurrences. Prefer correctness by invariant (proven
execution order, one declared entry point per flow) over correctness by state: every state
variable in the integration should justify itself, and most defensive guards agents write
for tracking turn out to be unnecessary once you trust the merge rules above.

## Modeling method

Work the mapping in three passes, global concerns first. Mistakes in earlier passes cost
the most; later passes are local problems with small blast radius that may be solved more
pragmatically.

**1. Flow boundaries.** For every flow, find the single best signal for when it starts,
when it finishes successfully, and — where the app has one — when it is skipped. Do this
for all flows (top-level and nested) before anything else. The verifiable result of this
pass: the boundaries of what is tracked are exactly defined. This is where precision
matters most — a `flow_finished` without a matching open flow invalidates the whole
session's classification. Give each flow one declared opener; every other handler drops
its signals when no flow is open.

**2. Decision structure.** Assign every screen of the journey to a decision name (see
Decisions — usually fewer names than screens), then find the simplest way to determine the
selectable option set per screen. Option sets are a local problem, but look for one
mechanism that yields options globally if the app offers it (e.g. a server response that
already lists the rendered choices, or determining actual visibility via tagged elements
in the DOM).

**3. Subflows.** Fill in one auth method attempt at a time. What matters is creating the
operation helper at the right moment (when the method appears or starts); then map the
app's signals onto the helper's steps where applicable.

The taxonomy is not a TODO list. Not every detail must be modeled: complexity trade-offs
and genuine mismatches between the app and the taxonomy are legitimate — prefer a clean
lossy mapping (documented) over a contorted complete one. Use subagents to verify the
integration against real journeys.

## Event catalog

| Event | SDK call | Sent when |
| --- | --- | --- |
| `flow_started` | `flowStarted()` | journey entry (one declared opener per flow) |
| `flow_decided` | `flowDecided()` | ambiguous entry resolves to one flow |
| `flow_finished` | `flowFinished()` | success, or explicit skip via `explicitOutcome` |
| `flow_auto_finished` | `flowAutoFinished()` | nested flow's terminal completes the parent |
| `flow_reset` | `flowReset()` | rarely — explicit restart |
| `auth_method_decision_started` | `authMethodsDecisionStarted()` | checkpoint rendered / options change |
| `auth_method_decision_finished` | `authMethodsDecisionFinished()` | navigational choice made (never for method choices) |
| `subflow_started` | helper construction (or `op.subflowStart({})`) | auth method appears or starts |
| `subflow_step_started/finished/error` | `op.<step>.start()/.finished()/.error()` | around the step's app logic |
| `flow_enriched` | `setCrossEnvironmentTransactionId()` | cross-environment handoff |
| `conversion` | `conversion()` | business conversion outside auth |

## Flows

Standard flow names: `login`, `signup`, `recovery`, `enrollment`. Custom flows take a
freeform name (e.g. account renewal, reauthentication, transaction signing).

**Finishing.** A flow is explicitly finished only on success — or when it is explicitly
skipped. Do not model non-completion on the client: incompleteness is classified from the
absence of a `flow_finished`. Skipping is the one exception because it is semantically
different from abandoning (e.g. "continue as guest", or entering signup abandons an open
recovery): send `flowFinished({ flowName, explicitOutcome: "skipped" })`.

```typescript
tracker?.flowStarted({ flowName: "login", touchpoint: "account" });
// ... success:
tracker?.flowFinished({ flowName: "login", userId: "usr_123", identifier: "max@example.com" });
```

When entry is ambiguous (combined login/signup form), start with
`flowNames: ["login", "signup"]` (+ optional `defaultFlowName`) and send
`flowDecided({ flowName })` once resolved.

**Nesting vs chaining.** Only `login` and `signup` can contain nested flows. A flow that
itself establishes the session (signup, recovery inside the login journey) nests inside
`login`; when the nested flow's own terminal fires, complete the parent with
`flowAutoFinished({ flowName: "login", finishedByFlowName: "signup", userId })`. A flow
that runs after the session already exists (typically enrollment prompted post-login) is
*chained*: a sibling flow started after the login finished, never nested.

Events always attribute to the innermost open flow. So when the user leaves a nested flow
without finishing it, close it explicitly (`explicitOutcome: "skipped"` is the usual fit —
e.g. entering signup skips an open recovery): it records the right outcome (skipped, not
abandoned) and keeps the parent's subsequent events out of the nested flow. This is the
one place where non-completion needs client help. Related edge: re-emitting the *outer*
flow's `flow_started` while a nested flow is open truncates back to the outer flow and
closes the nested one.

**Resets.** `flowReset()` exists but is rarely needed: whether a user restarted is
inferable later from revisited decisions and subflows. Don't emit it just to be tidy.

**Tags.** Flows are the natural carrier. Configuration tags (product, variant, device
class) ride `flow_started`; values only known on success ride `flow_finished`.
Tags are `Record<string, string>` passed as the second argument; last value per key wins
across a flow's events. Never put identity into tags — `userId`/`identifier` belong in
the user reference.

## Decisions

Use `authMethodsDecisionStarted` / `authMethodsDecisionFinished` for **all** decisions.

**Two kinds of options, one option set.** A screen's option set usually mixes both:

- **Method options** — the user chooses to attempt an auth method: start typing a
  password, click the passkey button. These use the predefined option strings (below) and
  are *never* finished explicitly: the subflow that follows resolves the decision in
  classification.
- **Navigational/routing options** — the user wants a different option set: switch
  verification method, change identifier, back, create account, enter recovery. Freeform
  names; finish explicitly with `explicitDecisionValue` the moment the choice is made,
  typically followed by the next screen's decision `started`.

Realistic logins have many navigational options — they are the adaptive, per-application
part of the model, not an edge case. Name them for reuse across decisions
(`switch-to-signup`, `back`, `recovery`).

```typescript
// screen renders
tracker?.authMethodsDecisionStarted({
  decisionName: "post-identifier",
  options: ["password-login-known-identifier", "passkey-login-known-identifier", "switch-to-otp", "back"],
});
// user picks a method → no finished; the password/passkey subflow resolves it.
// user picks navigation → finish explicitly:
tracker?.authMethodsDecisionFinished({
  decisionName: "post-identifier",
  explicitDecisionValue: "switch-to-otp",
});
```

**Decision names are checkpoints.** A decision name is a semantic unit of the journey —
usually a checkpoint that takes a successful auth method to pass and navigation to leave.
Multiple screens map to one name (progressive disclosure, explanatory screens, switching
between verification methods = still the same checkpoint). Typical names:
`pre-identifier` (everything before the identifier is submitted), `post-identifier` (the
method options shown after it), `2fa`. Rules that make names aggregate well:

- Every screen belongs to a decision, even with a single option.
- The same semantic screen always maps to the same name; a screen reused across
  checkpoints maps per surrounding context.
- Keep names short, stable, descriptive of the checkpoint.

Options ride `started`; an explicit `finished` needs only the decision name and the
chosen value (which should be one of the declared options). Keep the options array's
order stable across renders where possible.

Re-send `started` whenever the checkpoint is re-presented or its options change — each
rendered decision becomes its own occurrence and the superseded one closes as incomplete,
which is exactly what a revisited checkpoint should look like. Only dedup identical
consecutive offers caused by framework re-renders (compare by value). An option whose
subflow auto-starts on the screen still belongs in the option
set — if a subflow can start on a screen, its method option is part of that screen's
options. Unresolved decisions classify as incomplete.

**Option strings that subflows resolve.** The decision only resolves if the exact string
is present in `options`:

| Subflow (spec) | Option string |
| --- | --- |
| password-login (`password-known-identifier`) | `password-login-known-identifier` |
| password-login (`password-with-identifier`) | `password-login-with-identifier` |
| passkey-login (`passkey-known-identifier[-auto]`, `passkey-cui`, no spec) | `passkey-login-known-identifier` |
| passkey-login (`passkey-no-identifier[-auto]`) | `passkey-login-no-identifier` |
| passkey-login (`passkey-immediate`) | resolves no option (runs pre-decision) |
| password-login, CUI steps fired (`cui.*`) | `passkey-login-cui` |
| passkey-enrollment | `passkey-enrollment` |
| password-enrollment | `password-set` / `password-reset`, fallback `password-enrollment` |
| email-otp | `email-otp-login` / `email-otp-enrollment`, fallback `email-otp` |
| sms-otp | `sms-otp-login` / `sms-otp-enrollment`, fallback `sms-otp` |
| provide-identifier | `identifier-email` (also when its CUI part completes) |
| provide-data | `provide-data` |
| social-login | `social-google` / `social-apple` / `social-facebook` / `social-other` |
| app-confirmation | `qr-code` (dedicated QR screen) or `app-confirmation` |
| totp (low-level) | `totp` / `totp-enrollment` |

("fallback" = the subflow first tries the spec-typed string, then the generic one — put
whichever your option set naturally distinguishes.)

## Subflows

A subflow is one auth method attempt. Create the operation helper **when the method
appears on screen or starts** (a rendered password field, a shown OTP input, a passkey
process kicking off) — creation emits `subflow_started`. Repeated starts of the same
subflow with nothing in between are merged; don't guard against them.

```typescript
const op = tracker?.passkeyLoginFullOperation({ explicitSpecType: "passkey-known-identifier" });
try {
  op?.getOptions.start({});
  const options = await fetchAssertionOptions(email);
  op?.getOptions.finished({ assertionOptions: JSON.stringify(options) });
} catch (e) {
  op?.getOptions.error(e);
  return;
}
try {
  op?.ceremony.start({});
  const response = await startWebAuthnAuthentication(options);
  op?.ceremony.finished({ assertionResponse: JSON.stringify(response) });
} catch (e) {
  op?.ceremony.error(e); // also the user cancelling the prompt
  return;
}
try {
  op?.postResponse.start({});
  const result = await verifyOnServer(response);
  op?.postResponse.finished({}, { userReference: { userId: result.userId } });
} catch (e) {
  op?.postResponse.error(e);
}
```

Every helper takes a config with `autoStart?: boolean` (default `true`; disable only when
you must create the helper before the method is actually offered, then call
`op.subflowStart({})` yourself) and `explicitSpecType`.

| Helper (on tracker) | Subflow | Steps | Spec types |
| --- | --- | --- | --- |
| `provideIdentifierOperationFull(cfg?)` | provide-identifier (+ passkey CUI) | `provideIdentifier.clientValidation` / `.postResponse`; `cui.getOptions` / `.ceremony` / `.postResponse` | `email`, `phone`; CUI: `passkey-cui` |
| `passkeyLoginFullOperation(cfg?)` | passkey-login | `getOptions`, `ceremony`, `postResponse` | `passkey-known-identifier[-auto]`, `passkey-no-identifier[-auto]`, `passkey-cui`, `passkey-immediate` |
| `passkeyEnrollmentFullOperation(cfg?)` | passkey-enrollment | `getOptions`, `ceremony`, `postResponse` | `conditional-auto-manual`, `auto-manual`, `manual` |
| `passwordLoginFullOperation(cfg?)` | password-login | `clientValidation`, `postResponse`; `cui.getOptions` / `.ceremony` / `.postResponse` | `password-known-identifier`, `password-with-identifier`; CUI: `passkey-cui` |
| `passwordEnrollmentFullOperation(cfg?)` | password-enrollment | `clientValidation`, `postResponse` | `password-set`, `password-reset` |
| `emailOtpOperationFull(cfg?)` | email-otp | `send`, `postResponse`, `resend` | `email-otp-login`, `email-otp-enrollment` |
| `smsOtpOperationFull(cfg?)` | sms-otp | `postResponse`, `resend` | `sms-otp-login`, `sms-otp-enrollment` |
| `emailLinkOperationFull(cfg?)` | email-link | `send`, `postResponse`, `resend` | `email-link-login`, `email-link-enrollment` |
| `socialLoginOperationFull(cfg?)` | social-login | `getRedirectUrl`, `exchangeCode` | `pre-identifier`, `post-identifier` |
| `provideDataOperationFull(cfg?)` | provide-data | `clientValidation`, `postResponse` | `signup`, `login`, `recovery`, `enrollment` |
| `appConfirmationOperationFull(cfg?)` | app-confirmation | `ceremony`, `retry`, `postResponse` | `qr-code` |
| `captchaOperationFull(cfg?)` | captcha | `ceremony`, `postResponse` | `visible`, `invisible` |

For a subflow with no helper (e.g. TOTP), use the low-level tracker methods
(`trackSubflowStarted`, `trackSubflowStepStarted/Finished/Error`) with the same shape.
Custom steps: `op.customStep("my-step")`.

**Never finish a subflow.** There is no subflow-finished concept: the classifier derives
each attempt's outcome from its steps. The outcome-bearing step is `postResponse` for
almost every subflow (`exchangeCode` for social, `ceremony` for app-confirmation) — track
it always; earlier/utility steps are enrichment you may skip when the effort outweighs
the value — with one exception: the WebAuthn `ceremony` steps of the passkey subflows.
Track those whenever passkeys are in play; ceremony start/finished/error is what powers
all passkey-related analytics (engagement, cancellation, ceremony errors and durations)
and none of it is recoverable from `postResponse` alone. A completed ceremony without a
`postResponse` still classifies as incomplete,
because only the backend confirmation proves the method worked. (The low-level
`trackSubflowError` carries no outcome semantics — step errors are the intended channel;
don't use it.)

On failure, call `.error(e)` on the step that failed and stop; a retry is simply new step
events. See Step errors below for what to put into them.

**Spec types.** Supply `explicitSpecType` on the constructor whenever known. For
passkey-login, passkey-enrollment, password-enrollment, provide-data, email-link and
social-login a spec must eventually arrive on *some* event of the attempt — the
classifier drops an attempt without one. The types don't enforce this; it's the
integration's job to make sure one of these attempts never runs spec-less end to end. The others tolerate
absence with a documented default (email/sms-otp assume the login variant, password-login
`password-known-identifier`, provide-identifier `email`, app-confirmation `qr-code`).
When a spec only becomes known mid-attempt, send it on a later step's `start` data — the
last spec type wins in classification.

**Input binding.** Where the helper supports it, pass the input element
(`inputHtmlField`) for input-related subflows — it enables interaction capture on the
field. Call `op.destroy()` when the surface unmounts (input-bound helpers and the passkey
helpers hold event listeners).

**provide-data** covers form fields that request user data but map to no deeper subflow
concept (bank details, birth date, address...). One screen, one provide-data subflow on
the most important field; pass `fieldName` for the semantic name of what is collected.

**Parallel subflows** are fine as long as only one can plausibly receive interaction at a
time: a password field plus a passkey button on one screen is classifiable. A large form
where several tracked fields are filled and submitted together is not — model the
simplified version and track only the most important field (e.g. the password field on a
signup form).

## Step errors

Error tracking is an optional investment tier — classification never depends on it. An
attempt that just stops already classifies as incomplete; an explicit step error is a
*different* outcome (`<step>-error` vs `<step>-incomplete`), so errors add diagnostic
depth, not correctness. Map them to the depth the customer wants error analytics.

What makes the investment pay: the backend groups every reported error by its exact
signature — subflow type, step, code, message, spec type, latency bucket — into error
"flavours", which are then curated into named errors with impact analysis. Nothing is
dropped or bucketed as "other"; whatever the client sends is the raw material for
grouping. That yields four rules:

- **Platform errors go in raw.** For failures the platform produces — WebAuthn/browser
  exceptions, OS credential sheets — `.error(e)` with the caught exception is the right
  call: the platform's own vocabulary is already bounded (a cancelled or failed ceremony
  comes in only a handful of error names) and groups well as-is. Never withhold a real
  failure because it has no curated code.
- **The application's own errors deserve a deliberate shape.** Where the failure comes
  from the app's API or the transport/wire layer, decide explicitly what to send: a code
  naming what the client *observed*, not an interpretation (`invalid_password`,
  `invalid_otp`, `transport_failed`, `http_error`, `process_terminated`), reused where
  the same observation recurs across steps and platforms, with the server's raw error
  label as the message. The shape is untyped, so get it exactly right: pass a plain
  `{ code, message }` object to `.error()` — it nests both where classification reads
  them. Where a helper predefines typed codes, prefer `errorTyped` for the compile-time
  check (password login `invalid_password` / `user_not_found` / `account_locked`;
  password enrollment `requirements_not_fulfilled`; app-confirmation `declined` /
  `expired`; CUI ceremony `cancel_detected`).

  ```typescript
  op?.postResponse.start({});
  const body = await submitPassword(password);
  if (body.rejected) {
    // app's API refused the password — no exception in hand, name the observation:
    op?.postResponse.error({ code: "invalid_password", message: body.errorLabel });
    // ...or, where the helper types the code, compile-time checked:
    op?.postResponse.errorTyped({ code: "invalid_password" });
  }
  // caught platform exception (e.g. a WebAuthn ceremony) — pass it raw, don't rewrap:
  op?.ceremony.error(e);
  ```
- **Keep volatile tokens out of messages.** Request ids, timestamps and user data
  fragment the flavour grouping — it's per-occurrence tokens that hurt, not the number of
  distinct errors the app genuinely has.
- **No fallback codes.** A response you cannot confidently classify is neither success
  nor failure: leave the step open (it classifies incomplete) and surface the mapping gap
  through your own diagnostics instead. Not proving success is not failing — a guessed
  code pollutes exactly the analytics errors exist to feed.
- **User cancellation is an error on the step that observed it** — a dismissed passkey
  prompt is a `ceremony` error; the raw browser error is fine. The exception: an
  auto-offered method torn down because the user proceeded with another (e.g. a CUI
  request aborted by a password submit) is not an error.

## Event ordering

Ordering requirements are causal, not temporal:

1. `flow_started` before any event of that flow. A `flow_finished` or `flow_decided`
   without an open flow invalidates the session's classification — this is the unforgiving
   one.
2. When a screen renders: decision `started` before creating operation helpers (decision
   before `subflow_started`).
3. Settle the previous screen before opening the next: a navigational choice's decision
   `finished` precedes the next screen's decision `started`.
4. Nothing else. The backend orders by timestamp + emission sequence, repairs known race
   patterns and tolerates e.g. `subflow_started` arriving before
   `flow_started`. Use `explicitTimestamp` (on steps and decision `started`) to back-date
   when the semantic moment precedes the tracking call. Do not engineer ordering beyond
   rules 1–3.

## Cross-environment correlation

Events are correlated by a session id in local storage: everything sharing the JavaScript
process or local storage merges automatically — nothing to do. When a journey crosses a
boundary where local storage doesn't follow (another device, an iframe, some webview
setups), call `tracker.setCrossEnvironmentTransactionId(id)` **on both ends** with the
same id; the sessions are then merged in classification. How the id travels is the app's
choice — a magic link's query parameter, or an existing correlation id the system already
propagates.

## Setup

```bash
npm install @corbado/observe
```

`projectId` and `apiBaseUrl` come from the Corbado console (https://app.corbado.com →
Observe → Settings). Wrap `init()`/`getTracker()` in one module that lazily initializes
and returns `null` without config, and guard every call site with `?.` — tracking then
can't throw and is disabled wherever Observe isn't configured:

```typescript
import { getTracker, init, type CorbadoTracker } from "@corbado/observe";

let initialized = false;

export const observeTracker = (): CorbadoTracker | null => {
  const projectId = process.env.CORBADO_OBSERVE_PROJECT_ID; // adapt to the app's config
  const apiBaseUrl = process.env.CORBADO_OBSERVE_API_BASE_URL;
  if (!projectId || !apiBaseUrl) return null;
  if (!initialized) {
    init({ projectId, apiBaseUrl, debug: false });
    initialized = true;
  }
  return getTracker() ?? null;
};
```

Optional `init` options: `defaultTags` (stamped on every flow start and conversion),
`applicationId` (channel
like `"web"` when one project tracks several). Use `debug: true` while developing. Pass
`userId` (stable internal id; a hash is fine) and `identifier` as soon as identity is
known — at minimum on `flowFinished`, or per step via `{ userReference: {...} }`.

**Verify** by walking every instrumented journey (success, failure, cancel, skip) with
`debug: true`, checking the emitted series against the expectations below, and confirming
flows appear in the console dashboards.

## Worked example

Identifier-first login where the user backs out of the password screen and then signs up
instead — the event series a correct integration produces (`spec` = `explicitSpecType`):

```
flow_started            { flowName: login, touchpoint: account }        + config tags
auth_method_decision_started  { pre-identifier, options: [identifier-email, switch-to-signup, social-google] }
subflow_started         { provide-identifier }                          ← helper created on render
subflow_step_started    { provide-identifier, pi-post-response }        ← identifier submitted
subflow_step_finished   { provide-identifier, pi-post-response }        ← identifier accepted
                                                                        (resolves pre-identifier)
auth_method_decision_started  { post-identifier, options: [password-login-known-identifier,
                                passkey-login-known-identifier, back] }
subflow_started         { password-login }                              ← password field rendered
auth_method_decision_finished { post-identifier, explicitDecisionValue: back }   ← user clicks back
auth_method_decision_started  { pre-identifier, options: [...] }        ← same checkpoint, re-offered
auth_method_decision_finished { pre-identifier, explicitDecisionValue: switch-to-signup }
flow_started            { flowName: signup }                            ← nested in login
auth_method_decision_started  { signup-registration, options: [password-enrollment, back] }
subflow_started         { password-enrollment, spec: password-set }
subflow_step_started    { password-enrollment, post-response }          ← form submitted
subflow_step_finished   { password-enrollment, post-response }          (resolves signup-registration)
flow_finished           { flowName: signup, userId, identifier }
flow_auto_finished      { flowName: login, finishedByFlowName: signup, userId }
```

Note what is absent: no decision `finished` for the method choices (their subflows resolve
them), no subflow finishes (the `post-response` steps carry the outcomes), and no explicit
incomplete/abandon events anywhere — had the user left mid-journey, the absence of the
finishes would have classified it. The second `pre-identifier` decision is deliberately a
second occurrence: the user genuinely revisited that checkpoint.
