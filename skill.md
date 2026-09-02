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

The classifier merges where a repeat is unambiguous, and reads it as a restart where it is
not. Know which is which before emitting:

- A repeated `flow_started` for the _innermost_ open flow merges into it (latest
  `touchpoint` wins, tags accumulate).
- A repeated `flow_started` for an _outer_ flow while a nested flow is open is a restart:
  the classifier re-targets the outer flow and closes everything nested under it as
  incomplete. This is intended for real restarts (a reload mid-enrollment) and cannot be
  told apart from an accidental re-announce.
- Consecutive `subflow_started` of the same subflow type fold into one attempt (a
  different, known spec type starts a new attempt).
- Decisions: every presented decision surfaces as its own occurrence. A later re-emission —
  same or changed options — closes the open occurrence as incomplete and starts a new one;
  a revisited checkpoint is signal, not noise.

So flow-level events are emitted from one declared place per flow and never repeated
casually: the opener fires at the flow's own entry screens only, never from a nested
page "to make sure the parent is open". Subflow starts may repeat.
Decisions are emitted per _presentation_ (see Decisions). Prefer correctness by invariant
(proven execution order, one declared entry point per flow) over correctness by state:
every state variable in the integration should justify itself.

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
in the DOM). A screen can lead into the _same_ subflow through several controls (two
buttons that run the same ceremony, a primary tile plus an "other methods" list, a
prefilled versus typed identifier). That is one option and one subflow, since only one
option string can resolve; the difference is expressed through an explicit spec type where
the taxonomy has one, and otherwise modeled simplified: carry what differed as a tag
(typically on `flow_finished`) or accept the loss and document it.

**3. Subflows.** Fill in one auth method attempt at a time. What matters is creating the
operation helper at the right moment (when the method appears or starts); then map the
app's signals onto the helper's steps where applicable.

The taxonomy is not a TODO list. Not every detail must be modeled: complexity trade-offs
and genuine mismatches between the app and the taxonomy are legitimate — prefer a clean
lossy mapping (documented) over a contorted complete one. Use subagents to verify the
integration against real journeys.

## Event catalog

| Event                                 | SDK call                                       | Sent when                                           |
| ------------------------------------- | ---------------------------------------------- | --------------------------------------------------- |
| `flow_started`                        | `flowStarted()`                                | journey entry (one declared opener per flow)        |
| `flow_decided`                        | `flowDecided()`                                | ambiguous entry resolves to one flow                |
| `flow_finished`                       | `flowFinished()`                               | success, or explicit skip via `explicitOutcome`     |
| `flow_auto_finished`                  | `flowAutoFinished()`                           | nested flow's terminal completes the parent         |
| `flow_reset`                          | `flowReset()`                                  | rarely — explicit restart                           |
| `auth_method_decision_started`        | `authMethodsDecisionStarted()`                 | checkpoint rendered / options change                |
| `auth_method_decision_finished`       | `authMethodsDecisionFinished()`                | navigational choice made (never for method choices) |
| `subflow_started`                     | helper construction (or `op.subflowStart({})`) | auth method appears or starts                       |
| `subflow_step_started/finished/error` | `op.<step>.start()/.finished()/.error()`       | around the step's app logic                         |
| `flow_enriched`                       | `setCrossEnvironmentTransactionId()`           | cross-environment handoff                           |
| `conversion`                          | `conversion()`                                 | business conversion outside auth                    |

## Flows

Standard flow names: `login`, `signup`, `recovery`, `enrollment`. Custom flows take a
freeform name (e.g. account renewal, reauthentication, transaction signing).

**Finishing.** A flow is explicitly finished only on success — or when it is explicitly
skipped. Do not model non-completion on the client: incompleteness is classified from the
absence of a `flow_finished`. Skipping is the one exception because it is semantically
different from abandoning (e.g. "continue as guest", or entering signup abandons an open
recovery): send `flowFinished({ flowName, explicitOutcome: "skipped" })`. A skip can also
carry the user reference whenever identity is already known.

```typescript
tracker?.flowStarted({ flowName: "login", touchpoint: "account" });
// ... success:
tracker?.flowFinished({
    flowName: "login",
    userId: "usr_123",
    identifier: "max@example.com"
});
```

When entry is ambiguous (combined login/signup form), start with
`flowNames: ["login", "signup"]` (+ optional `defaultFlowName`) and send
`flowDecided({ flowName })` once resolved.

**Nesting vs chaining.** Only `login` and `signup` can contain nested flows. A flow that
itself establishes the session (signup, recovery inside the login journey) nests inside
`login`; when the nested flow's own terminal fires, complete the parent with
`flowAutoFinished({ flowName: "login", finishedByFlowName: "signup", userId })`. A flow
that runs after the session already exists (typically enrollment prompted post-login) is
_chained_: a sibling flow started after the login finished, never nested.

Events always attribute to the innermost open flow. So when the user leaves a nested flow
without finishing it, close it explicitly (`explicitOutcome: "skipped"` is the usual fit —
e.g. entering signup skips an open recovery): it records the right outcome (skipped, not
abandoned) and keeps the parent's subsequent events out of the nested flow. This is the
one place where non-completion needs client help. The reverse also holds: never re-emit
the _outer_ flow's `flow_started` while a nested flow is open — the classifier reads it as
a restart and closes the nested flow as incomplete (see System context).

**Resets.** `flowReset()` exists but is rarely needed: whether a user restarted is
inferable later from revisited decisions and subflows. Don't emit it just to be tidy.

**Tags.** Flows are the natural carrier. Configuration tags (product, variant, device
class) ride `flow_started`; values only known on success ride `flow_finished`.
Tags are `Record<string, string>` passed as the second argument; last value per key wins
across a flow's events. Never put identity into tags — `userId`/`identifier` belong in
the user reference. Do not re-fire the opener from reactive config (store hydration,
feature flags) just to refresh its tags; late-known values go on `flow_finished`.

## Decisions

Use `authMethodsDecisionStarted` / `authMethodsDecisionFinished` for **all** decisions.

**Two kinds of options, one option set.** A screen's option set usually mixes both:

- **Method options** — the user chooses to attempt an auth method: start typing a
  password, click the passkey button. These use the predefined option strings (below) and
  are _never_ finished explicitly: the subflow that follows resolves the decision in
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
    options: [
        "password-login-known-identifier",
        "passkey-login-known-identifier",
        "switch-to-otp",
        "back"
    ]
});
// user picks a method → no finished; the password/passkey subflow resolves it.
// user picks navigation → finish explicitly:
tracker?.authMethodsDecisionFinished({
    decisionName: "post-identifier",
    explicitDecisionValue: "switch-to-otp"
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

A decision occurrence is a _presentation to the user_, not a render. Re-send `started`
whenever the checkpoint is re-presented or its options change — each presentation becomes
its own occurrence and the superseded one closes as incomplete, which is exactly what a
revisited checkpoint should look like. An identical offer with no user action or
navigation in between is the same presentation and must not be re-emitted (framework
re-renders, route remounts, hydration); a click-driven decision is always a new
presentation. Engaging a method resolves the decision regardless of how the attempt ends,
so a failed attempt on an unchanged screen is a retry inside the same occurrence, not a
reason to re-emit `started`. When the option set depends on an async capability check
(conditional mediation, platform authenticator availability), emit `started` synchronously
on render with `explicitTimestamp` set to the render time, and re-emit with the final
options and the _same_ timestamp once the check resolves: an identical timestamp replaces
the open occurrence's options in place instead of opening a new one. Capture the render
time once and reuse it. An option whose subflow auto-starts on the screen still belongs in
the option set — if a subflow can start on a screen, its method option is part of that
screen's options. Unresolved decisions classify as incomplete.

**Option strings that subflows resolve.** The decision only resolves if the exact string
is present in `options`:

| Subflow (spec)                                                            | Option string                                                                                                                              |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| password-login (`password-known-identifier`)                              | `password-login-known-identifier`                                                                                                          |
| password-login (`password-with-identifier`)                               | `password-login-with-identifier`                                                                                                           |
| passkey-login (`passkey-known-identifier[-auto]`, `passkey-cui`, no spec) | `passkey-login-known-identifier`                                                                                                           |
| passkey-login (`passkey-no-identifier[-auto]`)                            | `passkey-login-no-identifier`                                                                                                              |
| passkey-login (`passkey-immediate`)                                       | resolves no option (runs pre-decision)                                                                                                     |
| password-login, CUI steps fired (`cui.*`)                                 | `passkey-login-cui` (password-login helper only)                                                                                           |
| passkey-enrollment                                                        | `passkey-enrollment`                                                                                                                       |
| password-enrollment                                                       | `password-set` / `password-reset`, fallback `password-enrollment`                                                                          |
| email-otp                                                                 | `email-otp-login` / `email-otp-enrollment`, fallback `email-otp`                                                                           |
| sms-otp                                                                   | `sms-otp-login` / `sms-otp-enrollment`, fallback `sms-otp`                                                                                 |
| provide-identifier                                                        | `identifier-email` (also when its CUI part completes; a CUI ceremony torn down by the identifier submit is neutral — no error, no abandon) |
| provide-data                                                              | `provide-data`                                                                                                                             |
| social-login                                                              | `social-google` / `social-apple` / `social-facebook` / `social-other`                                                                      |
| app-confirmation                                                          | `qr-code` (dedicated QR screen) or `app-confirmation`                                                                                      |
| totp (low-level)                                                          | `totp` / `totp-enrollment`                                                                                                                 |

("fallback" = the subflow first tries the spec-typed string, then the generic one — put
whichever your option set naturally distinguishes.)

## Subflows

A subflow is one auth method attempt; creating the operation helper emits
`subflow_started`. When to create it depends on how the method is engaged:

- **Input-bound methods** (password, OTP, identifier, provide-data) start when the input
  renders — the field itself is the attempt surface, and the helper captures interaction
  on it.
- **Action-bound methods** (passkey button, social button, app confirmation) start on the
  action, not when the button becomes visible. A visible option is not an attempt; a helper
  created for a button nobody pressed classifies as an attempt with no follow-up, i.e. an
  error.

A helper starts its attempt exactly once: construction auto-starts by default, so never add
a manual `subflowStart()` on top of it. Repeated starts of the same subflow with nothing in
between are merged; don't guard against them. Do not emit `subflow_trigger`; it is
deprecated for the helpers used here and carries no classification value.

Instrumentation is additive by default: it observes the app's existing lifecycle and does
not add cancellation, timers, navigation rules or request signals of its own. Where a clean
attempt boundary genuinely needs a small restructuring (a single choke point for a
ceremony, a teardown hook), make it deliberately and call it out in the mapping notes.

```typescript
const op = tracker?.passkeyLoginFullOperation({
    explicitSpecType: "passkey-known-identifier"
});
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

The passkey steps carry the WebAuthn payloads as JSON strings: for login,
`getOptions.finished` takes `assertionOptions` and `ceremony.finished` takes
`assertionResponse`; for enrollment the same steps take `attestationOptions` and
`attestationResponse`, and the enrollment `ceremony.start` additionally requires
`mediation` (`"conditional" | "optional" | "required"`).

**Identifier-field Conditional UI** is not a passkey-login attempt. It belongs to the
provide-identifier helper's `cui` steps, resolves the same `identifier-email` option, and
runs alongside the manual identifier path:

```typescript
const op = tracker?.provideIdentifierOperationFull({
    inputHtmlField: emailInput,
    explicitSpecType: "email"
});
// conditional request, started when the identifier surface renders:
op?.cui.getOptions.start({ explicitSpecType: "passkey-cui" });
const options = await fetchConditionalOptions();
op?.cui.getOptions.finished({ assertionOptions: JSON.stringify(options) });
op?.cui.ceremony.start({});
try {
    const response = await startConditionalWebAuthn(options); // pending until picked or torn down
    op?.cui.ceremony.finished({ assertionResponse: JSON.stringify(response) });
    op?.cui.postResponse.start({});
    const result = await verifyOnServer(response);
    op?.cui.postResponse.finished(
        {},
        { userReference: { userId: result.userId } }
    );
} catch (e) {
    // torn down because the user submitted the identifier or left: not an error
    if (!displacedByUser) op?.cui.ceremony.error(e);
}
// manual path, on submit:
op?.provideIdentifier.postResponse.start({});
```

**Read the installed package before applying a recipe.** Helper signatures can move between
releases.

| Helper (on tracker)                     | Subflow                            | Steps                                                                                                    | Spec types                                                                                            |
| --------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `provideIdentifierOperationFull(cfg?)`  | provide-identifier (+ passkey CUI) | `provideIdentifier.clientValidation` / `.postResponse`; `cui.getOptions` / `.ceremony` / `.postResponse` | `email`, `phone`; CUI: `passkey-cui`                                                                  |
| `passkeyLoginFullOperation(cfg?)`       | passkey-login                      | `getOptions`, `ceremony`, `postResponse`                                                                 | `passkey-known-identifier[-auto]`, `passkey-no-identifier[-auto]`, `passkey-cui`, `passkey-immediate` |
| `passkeyEnrollmentFullOperation(cfg?)`  | passkey-enrollment                 | `getOptions`, `ceremony`, `postResponse`                                                                 | `conditional-auto-manual`, `auto-manual`, `manual`                                                    |
| `passwordLoginFullOperation(cfg?)`      | password-login                     | `clientValidation`, `postResponse`; `cui.getOptions` / `.ceremony` / `.postResponse`                     | `password-known-identifier`, `password-with-identifier`; CUI: `passkey-cui`                           |
| `passwordEnrollmentFullOperation(cfg?)` | password-enrollment                | `clientValidation`, `postResponse`                                                                       | `password-set`, `password-reset`                                                                      |
| `emailOtpOperationFull(cfg?)`           | email-otp                          | `send`, `postResponse`, `resend`                                                                         | `email-otp-login`, `email-otp-enrollment`                                                             |
| `smsOtpOperationFull(cfg?)`             | sms-otp                            | `postResponse`, `resend`                                                                                 | `sms-otp-login`, `sms-otp-enrollment`                                                                 |
| `emailLinkOperationFull(cfg?)`          | email-link                         | `send`, `postResponse`, `resend`                                                                         | `email-link-login`, `email-link-enrollment`                                                           |
| `socialLoginOperationFull(cfg?)`        | social-login                       | `getRedirectUrl`, `exchangeCode`                                                                         | `pre-identifier`, `post-identifier`                                                                   |
| `provideDataOperationFull(cfg?)`        | provide-data                       | `clientValidation`, `postResponse`                                                                       | `signup`, `login`, `recovery`, `enrollment`                                                           |
| `appConfirmationOperationFull(cfg?)`    | app-confirmation                   | `ceremony`, `retry`, `postResponse`                                                                      | `qr-code`                                                                                             |
| `captchaOperationFull(cfg?)`            | captcha                            | `ceremony`, `postResponse`                                                                               | `visible`, `invisible`                                                                                |

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
social-login a spec must eventually arrive on _some_ event of the attempt — the
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
_different_ outcome (`<step>-error` vs `<step>-incomplete`), so errors add diagnostic
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
  naming what the client _observed_, not an interpretation (`invalid_password`,
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
        op?.postResponse.error({
            code: "invalid_password",
            message: body.errorLabel
        });
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
   one. `flow_auto_finished` without an open parent is dropped silently, not fatal.
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
Observe → Settings). Wrap `init()`/`getTracker()` in one module that lazily initializes,
and guard every call site with `?.` — tracking then can't throw:

```typescript
import { getTracker, init, type CorbadoTracker } from "@corbado/observe";

let initialized = false;

export const observeTracker = (): CorbadoTracker | null => {
    const projectId = "pro-XXX"; // adapt to your project id
    const apiBaseUrl = "https://api.cloud.corbado.io";
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

## Validating the implementation

Tracking cannot be proven from the app's own tests; the raw event series is what the
classifier sees. After implementing, it can be useful to pick a small set of journeys
with decent coverage and write down the event series each should produce, in the notation
of the worked example below.
Then have the developer run those journeys with `debug: true` and hand back the console
output: the SDK logs every emitted event with its data. Read the series against the rules
in this skill and fix what deviates before looking at dashboards.

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
