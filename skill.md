---
name: corbado-observe
description: Integrate Corbado Observe into a frontend application to measure
    authentication flows like login, signup, recovery or enrollment. Use when adding
    Corbado Observe, authentication analytics or passkey/login funnel tracking
    to an app.
---

# Corbado Observe integration

Corbado Observe is fire-and-forget telemetry for authentication journeys. The
application's auth journeys are mapped onto Observe's taxonomy — flows, decisions,
subflows — and a backend classifier turns the event stream into funnels and analytics.

Every Observe integration has the same two halves, whatever its shape:

- **Signal sources** — what the browser or the app reveals: screens, choices, requests,
  validation results, WebAuthn ceremonies.
- **One mapping** — the single place that turns those signals into Observe taxonomy calls
  through `@corbado/observe`.

The shapes differ only in where the signals come from and who owns the mapping:

| Shape                                    | Signals                                                                                | Mapping                                     | App changes                            |
| ---------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------- | -------------------------------------- |
| Autocapture                              | Browser surfaces via `@corbado/autocapture` (network, WebAuthn, DOM, existing low events) | Built and maintained by Corbado, reconciled after app releases | none — implemented and maintained by Corbado |
| **Data layer + mapping** (default here)  | A handful of semantic events the app pushes into a page-global data layer, plus fallbacks | One central module, Corbado-shaped, swappable | a three-line shim plus thin emitters   |
| Custom events (precision)                | Tracker calls written into the app's own code at the semantic points                   | Spread across the app's components          | tracker calls at every semantic point  |

Delivery — self-hosted package or Corbado script tag (recommended) — is a separate
dimension that applies to Autocapture and the data layer alike (section 6).

**Scope: this skill is for customers integrating from their own source. It implements the
data layer + mapping shape by default and uses custom events only under the conditions in
section 1.** Autocapture is implemented and maintained by Corbado and is not built with
this skill. All three shapes write into the same project, session and data model.
`@corbado/autocapture` is the low-level capture library the mapping uses for fallbacks; it
is not the tracker SDK.

## 1. Decide the integration shape

First rule out Autocapture. A user who wants **no source changes at all** — a fully managed
solution where Corbado derives everything from what is already there (API calls, WebAuthn,
fields and low events, existing component events) and reconciles the tracking after larger
releases — wants Autocapture. Corbado implements and maintains it; it is not built with
this skill. Stop and point the user to Corbado (support@corbado.com).

Otherwise default to the data layer + mapping. Use the precision path (section 9) only when
one of these holds:

- The user explicitly asks for precision tracking, custom events or single events.
- There is no structurally sound central place: the auth journey is spread over
  independently deployed surfaces with no shared script scope, or the app is so complex
  that funnelling its signals through one layer would be a larger change than
  instrumenting it directly.

When in doubt, ask before writing code. State the trade-off like this:

> Observe can be integrated three ways. **Data layer + mapping:** your code pushes a few
> semantic events (screen shown, option chosen, request settled, validation failed) into
> a small in-page buffer, and one central module maps them onto Observe. Benefits: no
> tracking calls scattered through components, the whole tracking model is readable in one
> place, Corbado can review and optimize that module together with you, and new tracking
> logic is testable by replaying recorded events. Before go-live the module can ship as
> your own package or from Corbado's CDN, so tracking corrections need no app release.
> **Custom events:** tracker calls at every semantic point in your code. Every tracking
> correction is an app release, and there is no central place Corbado can optimize with
> you. **Autocapture:** no code changes at all, fully managed by Corbado, set up with
> Corbado rather than here. Which do you want?

What each side owns in the default shape:

| The app keeps                                                    | The mapping owns                                                                          |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| The shim, inserted first in `<head>`                             | Taking over the data layer and replaying its buffer                                       |
| Emitters using the app's own stable names for screens, controls and requests | Translation into Observe decision names, option strings, subflows and spec types |
| Projected request results — named facts, never raw bodies         | Flow lifecycle: which screens open which flow, which request finishes it, what counts as skipped |
| Validation results from its own validation pass                  | Every `@corbado/observe` call                                                             |
| Context: user reference, experiments, tags, consent, touchpoint  | Fallback capture via `@corbado/autocapture` where the app cannot emit                     |

**Hard rule:** the mapping module imports only its own contract types, `@corbado/observe`
and `@corbado/autocapture`. Never app internals. That is what makes it replaceable by an
npm package, a CDN script or an injected build without touching the app. The data layer
speaks the app's vocabulary; the mapping speaks Observe's.

## 2. System context: model for the classifier, not the event log

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
(proven execution order, one declared entry point per flow) over correctness by state.
In the default shape all tracking state lives in the mapping, in one owned place; the
app's emitters hold none — they report facts at the moment they happen.

## 3. Modeling method

Work the mapping in three passes, global concerns first. Mistakes in earlier passes cost
the most; later passes are local problems with small blast radius that may be solved more
pragmatically. Each pass produces one table of the mapping's `taxonomy.ts` (section 5).

**1. Flow boundaries.** For every flow, find the single best signal for when it starts,
when it finishes successfully, and — where the app has one — when it is skipped. Do this
for all flows (top-level and nested) before anything else. The verifiable result of this
pass: the boundaries of what is tracked are exactly defined. This is where precision
matters most — a `flow_finished` without a matching open flow invalidates the whole
session's classification. Give each flow one declared opener; every other handler drops
its signals when no flow is open. In the default shape the opener is a screen: the flow
table names the entry screens of every flow, the request whose success finishes it, and
the screen transitions that mean a nested flow was skipped. Nothing about flows is emitted
by the app.

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
(typically on `flow_finished`) or accept the loss and document it. The screen table maps
each app screen name to its decision name and each app control name to an Observe option
string.

**3. Subflows.** Fill in one auth method attempt at a time. What matters is creating the
operation helper at the right moment (when the method appears or starts); then map the
app's signals onto the helper's steps where applicable. The request table maps each app
request name to a subflow step and names the projected result fields the mapping reads.

Not every taxonomy detail needs instrumentation. Complexity trade-offs and mismatches
between the app and the taxonomy are legitimate — prefer a clean
lossy mapping (documented) over a contorted complete one. Use subagents to verify the
integration against real journeys.

## 4. The Observe data layer (app side)

### 4.1 The shim

```html
<script>
    window.corbadoDataLayer = window.corbadoDataLayer || [];
</script>
```

Inline, the first script in `<head>`, before any app code. It is a plain push array with
the mechanics of an analytics data layer: pushes accumulate until the mapping loads and
takes over `push`, then every buffered event is replayed in order. That buffer is what
makes a late-loading mapping lossless — a request that fired before the mapping arrived
still reaches it. Never put the shim behind the app's own enablement or consent gate.
Whether collecting into the in-memory buffer before consent is acceptable is the
customer's privacy call: the mapping starts _sending_ only after consent (see `context`).
If collecting before consent is not allowed, insert the shim after consent and accept that
earlier journeys are not recorded.

Push events with `window.corbadoDataLayer.push(...)` from app code; wrap it in a tiny
typed helper so emitters cannot throw:

```typescript
import type { DataLayerEvent } from "./observe-mapping/contract";

export const observe = (event: DataLayerEvent): void => {
    try {
        (window.corbadoDataLayer ||= []).push(event);
    } catch {
        // telemetry never throws into the app
    }
};
```

### 4.2 Event contract

Six event kinds. Names in the app's own vocabulary; timestamps in epoch milliseconds
taken at the semantic moment.

| Event        | Fields                                                                                                                   | Push when                                                                                              |
| ------------ | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| `screen`     | `name`, `options: string[]` (control names, stable order), `ts`, `input?` (the primary `HTMLInputElement`), `tags?`     | every _presentation_ of a screen, synchronously on render, before any request the screen auto-starts   |
| `choice`     | `screen`, `option` (a control name from that screen's options), `ts?`                                                    | the moment a control is used, before the request it starts and before the next screen                  |
| `request`    | `name`, `id`, `phase: "started" \| "finished" \| "failed"`, `ts`, on settle `result?` (projected facts), `code?`, `message?` | from the API client choke point: `started` at send, `finished`/`failed` at settle, before the next screen renders |
| `validation` | `screen`, `field`, `code`, `message?`, `ts?`                                                                             | from the app's own validation pass, one per rejected field, before any request                          |
| `context`    | `user?` (`userId`, `identifier`, `crossEnvironmentTransactionID`), `experiments?`, `tags?`, `application?`, `touchpoint?`, `consent?` | whenever a fact becomes known; `touchpoint` with or before the entry screen; `user` before the terminal request settles |
| `ceremony`   | `kind: "authentication" \| "registration"`, `phase`, `id`, `mediation?`, `options?`, `credential?`, `error?`, `ts`     | only when the app owns the `navigator.credentials` call and can attach the live options and credential objects; otherwise omit — the mapping captures ceremonies itself |

```typescript
export type DataLayerEvent =
    | { event: "screen"; name: string; options: string[]; ts: number; input?: HTMLInputElement; tags?: Record<string, string> }
    | { event: "choice"; screen: string; option: string; ts?: number }
    | { event: "request"; name: string; id: string; phase: "started"; ts: number }
    | { event: "request"; name: string; id: string; phase: "finished" | "failed"; ts: number;
        result?: Record<string, string | number | boolean>; code?: string; message?: string }
    | { event: "validation"; screen: string; field: string; code: string; message?: string; ts?: number }
    | { event: "context"; user?: { userId?: string; identifier?: string; crossEnvironmentTransactionID?: string };
        experiments?: Record<string, string>; tags?: Record<string, string>;
        application?: string; touchpoint?: string; consent?: boolean }
    | { event: "ceremony"; kind: "authentication" | "registration"; phase: "started" | "completed" | "failed";
        id: string; mediation?: "conditional" | "optional" | "required" | "silent";
        options?: object; credential?: object; error?: unknown; ts: number };
```

### 4.3 Emission rules

- **One push per fact, at the moment it happens, synchronously.** No batching, no
  debouncing, no state in the emitters.
- **`screen` is per presentation, not per render.** Re-push when the checkpoint is
  re-presented or its options change; never for framework re-renders, route remounts or
  hydration. When the option set depends on an async capability check, push the screen on
  render and push it again with the final options and the _same_ `ts` — the mapping turns
  that into an in-place replacement (see Decisions). Include the option whose method
  auto-starts on the screen. Pass the primary input element: it powers interaction capture
  on input-bound methods.
- **`choice` covers both kinds of options.** Method choices (typing a password, pressing
  the passkey button) and navigational choices (back, switch method, forgot password) are
  both pushed; the mapping decides which ones finish a decision explicitly.
- **`request` comes from the API client, not from components.** Most apps have one module
  that issues auth calls — emit there, once. `result` carries named facts the mapping needs
  (`{ status: "PASSWORD_REQUIRED" }`, `{ known: true }`, `{ loggedIn: true }`); never a
  request or response body, never identifiers, passwords, OTPs or credential JSON. On
  failure, `code` names what the client observed (`invalid_password`, `http_error`,
  `transport_failed`) and `message` carries the server's raw error label without volatile
  tokens.
- **`validation` replaces DOM inference.** The app knows which field its validation pass
  rejected and why; push that instead of letting anyone read error markup. `code` is the
  native `ValidityState` key where one applies (`valueMissing`, `typeMismatch`), else the
  app's own rule name.
- **`context` is additive.** Push the user reference as soon as identity is known and
  before the terminal request settles, so the mapping can call `setUser()` inside the flow
  it belongs to. Push `consent: false` when consent is revoked; the mapping tears the
  tracker down.
- **Ordering invariants the app guarantees:** `screen` before any request that screen
  auto-starts; `choice` before the request it starts and before the next `screen`;
  `request` settled before the next `screen` renders (natural when emitted from the API
  client); `context.touchpoint` with or before the entry screen.
- **Stable names.** Screen, control and request names are the contract with the mapping.
  Change them deliberately and update the mapping's tables in the same change.

```typescript
// identifier screen renders (options in stable order; the email field is the primary input)
observe({ event: "screen", name: "identifier", options: ["email", "google", "signup-link"], ts: Date.now(), input: emailInput });
// user clicks "Create account"
observe({ event: "choice", screen: "identifier", option: "signup-link" });
// API client: identifier lookup
observe({ event: "request", name: "checkIdentifier", id, phase: "started", ts: Date.now() });
observe({ event: "request", name: "checkIdentifier", id, phase: "finished", ts: Date.now(), result: { known: true } });
// app's own validation pass rejected the field
observe({ event: "validation", screen: "identifier", field: "email", code: "typeMismatch" });
// identity known after the session was established
observe({ event: "context", user: { userId: hashedUserId } });
```

### 4.4 Bridging to the analytics data layer

The Observe data layer has the same mechanics as an analytics data layer and the same
event shape (one object with an `event` key and a flat payload), on purpose:

- **Mirror outward.** Where the customer wants auth events in their own analytics, push
  the same objects into their data layer as well — from the emitter, never from the mapping.
- **Consume existing events.** Where the app already pushes auth facts into its analytics
  data layer, the mapping may subscribe to those as a signal source instead of asking for
  new emitters. Treat them like any fallback source: declared, optional, and never trusted
  for ordering the app does not guarantee.
- **Do not push into the customer's tag manager array.** Other tags would see the events,
  tag managers merge pushed objects in ways that mangle DOM references, and they load late
  and behind consent gates. Keep `corbadoDataLayer` separate.

## 5. The mapping (the central module)

### 5.1 Layout

```
observe-mapping/
  index.ts        install(): init the tracker, take over the data layer, replay the buffer, attach fallbacks
  contract.ts     DataLayerEvent (shared with the app's emitters) — the only import the app makes from here
  taxonomy.ts     the three tables: flows, screens, requests; all Observe vocabulary lives here
  coordinator.ts  flow lifecycle from the flow table; routes events to the active screen state
  states/         one class per app screen: decision, helpers, steps
  fallbacks.ts    @corbado/autocapture wiring (WebAuthn always, network when needed) + availability flags
```

Both of Corbado's production adapters have exactly this shape; it is what keeps a mapping
readable after a year of changes. Corbado can supply a sample skeleton for the customer's
stack — ask before inventing one.

### 5.2 Taking over the layer

```typescript
import { init } from "@corbado/observe";
import type { DataLayerEvent } from "./contract";
import { Coordinator } from "./coordinator";
import { attachFallbacks } from "./fallbacks";

export function installObserveMapping(options: { projectId: string; apiBaseUrl: string; debug?: boolean }) {
    if (typeof window === "undefined" || window.top !== window.self) return () => {}; // frames don't own the journey
    const layer = (window.corbadoDataLayer ||= []);
    const tracker = init(options);
    const coordinator = new Coordinator(tracker);
    const consume = (event: DataLayerEvent) => {
        try {
            coordinator.handle(event);
        } catch (error) {
            tracker.telemetry("error", `mapping failed on ${event.event}`); // contain: never throw into the app
        }
    };
    const pending = layer.splice(0);
    layer.push = (...events: DataLayerEvent[]) => {
        events.forEach(consume);
        return layer.length;
    };
    pending.forEach(consume);
    const fallbacks = attachFallbacks(coordinator, tracker);
    return () => {
        fallbacks.dispose();
        coordinator.destroy();
        void tracker.destroy();
    };
}
```

Install as early as the delivery mode allows (section 6). Everything the app pushed
before that moment is replayed in arrival order, so emission order is preserved.

### 5.3 Coordinator: flow lifecycle from tables

The coordinator owns flows and nothing else. It derives every flow event from the flow
table, the same way Corbado's own adapters do:

```typescript
export const FLOWS = {
    // app screen → the flow it opens; nested flows open inside the innermost open login/signup
    entry: { identifier: "login", "signup-form": "signup", "recovery-email": "recovery", "enroll-passkey": "enrollment" },
    // request → the flow its success finishes; `when` reads the projected result
    terminal: {
        createSession: { flow: "login", when: (r) => r?.loggedIn === true },
        completeSignup: { flow: "signup" },
        resetPassword: { flow: "recovery" },
        registerPasskey: { flow: "enrollment" },
    },
    // a screen whose render means these still-open nested flows were left: closed as skipped
    skip: { identifier: ["signup", "recovery"], password: ["signup", "recovery"] },
    // a choice that skips the flow it is made in
    skipChoice: { "enroll-passkey": ["not-now"] },
} as const;
```

Rules the coordinator enforces (see section 8 for the classifier reasons):

- `screen` with an entry mapping opens the flow if it is not already open — once, with the
  current `touchpoint` and tags from `context`. A repeated entry screen inside an open flow
  does not re-open it; an entry screen after the flow finished opens a new one.
- A screen in `skip` closes the listed nested flows with `explicitOutcome: "skipped"`
  before the screen's own state is entered.
- A terminal request `finished` (and `when` true) calls `setUser()` with the latest known
  reference, then `flowFinished()`; a nested flow's terminal also completes its parent with
  `flowAutoFinished({ flowName: parent, finishedByFlowName: nested })`. Call
  `tracker.flushKeepalive()` right after a terminal, because the app usually navigates away.
- A request result that resolves an ambiguous entry (`{ known: true }` on a combined form)
  emits `flowDecided()`.
- Routing: on `screen`, exit the current state, look the screen up in the screen table,
  construct its state, enter it. Every other event goes to the active state. A screen with
  no state maps to an `Unmapped` state that emits nothing and reports the gap through
  `tracker.telemetry("info", ...)` — an interface the mapping cannot name is a missing
  mapping, not an expected outcome.

### 5.4 Screen states

One class per app screen. A state owns its decision, its operation helpers and the steps
its requests map to. Sketch of a post-identifier screen with password, passkey and
forgot-password:

```typescript
import type { CorbadoTracker, PasskeyLoginOperationFull, PasswordLoginOperationFull } from "@corbado/observe";
import { OPTIONS } from "../taxonomy"; // control name → Observe option string
import { settle, ceremony } from "../steps"; // small helpers: request phase → step call

export class PasswordScreen {
    private password?: PasswordLoginOperationFull;
    private passkey?: PasskeyLoginOperationFull;
    constructor(private readonly tracker: CorbadoTracker) {}

    enter(screen: Extract<DataLayerEvent, { event: "screen" }>) {
        this.tracker.authMethodsDecisionStarted(
            { decisionName: "post-identifier", options: screen.options.map((o) => OPTIONS.password[o]) },
            undefined,
            undefined,
            { explicitTimestamp: screen.ts },
        );
        // input-bound method: the attempt surface is the field, so the helper is created on render
        if (screen.input) {
            this.password = this.tracker.passwordLoginFullOperation({
                inputHtmlField: screen.input,
                explicitSpecType: "password-known-identifier",
            });
        }
    }

    choice(option: string) {
        switch (option) {
            case "passkey-button": // action-bound method: helper created on the action
                this.passkey = this.tracker.passkeyLoginFullOperation({ explicitSpecType: "passkey-known-identifier" });
                return;
            case "forgot-password": // navigational: finish explicitly; the next screen's decision follows
                this.tracker.authMethodsDecisionFinished({ decisionName: "post-identifier", explicitDecisionValue: "recovery" });
                return;
        }
    }

    request(e: Extract<DataLayerEvent, { event: "request" }>) {
        switch (e.name) {
            case "verifyPassword":
                return settle(this.password?.postResponse, e, { typed: { invalid_password: "invalid_password" } });
            case "passkeyOptions":
                return settle(this.passkey?.getOptions, e);
            case "verifyPasskey":
                return settle(this.passkey?.postResponse, e);
        }
    }

    ceremony(e: CeremonySignal) {
        ceremony(this.passkey?.ceremony, e); // start/finished/error with sanitized options and credential
    }

    validation(e: Extract<DataLayerEvent, { event: "validation" }>) {
        if (e.field === "password") this.password?.clientValidation.error({ name: "ClientValidationError", code: e.code });
    }

    exit() {
        this.password?.destroy();
        this.passkey?.destroy();
    }
}
```

`settle()` maps `started` to `step.start({}, { explicitTimestamp: e.ts })`, `finished` to
`step.finished({}, ...)`, and `failed` to `step.errorTyped({ code })` when the code is in the
helper's typed set and `step.error({ code, message })` otherwise. `ceremony()` maps a
ceremony signal — from the app or from the WebAuthn fallback — onto the passkey helper's
`ceremony` step, passing the sanitized options on `start` and the sanitized credential on
`finished`. Write both helpers once in `steps.ts`.

### 5.5 Fallback sources from `@corbado/autocapture`

The data layer is the primary source. Fallbacks fill what the app cannot emit:

- **WebAuthn — attach by default.** `captureWebAuthn({ onEvent })` observes every
  `navigator.credentials.get/create` on the page, including ceremonies run by third-party
  auth libraries that expose no hooks, and delivers sanitized `requestOptionsJson`,
  `creationOptionsJson` and `credentialJson` plus mediation, UI mode and the error. Route
  its events to the active state's `ceremony()`. Only skip it when the app emits `ceremony`
  events itself; then run the package sanitizers (`sanitizeRequestOptions`,
  `sanitizeCreationOptions`, `sanitizeAssertionResponse`, `sanitizeCreationResponse`) on the
  live objects before they reach a step. Credential JSON never enters the mapping any other
  way.
- **Network — attach only when there is no API client choke point.** `captureNetwork` with
  a `match` for the auth endpoints and body projectors that allowlist exactly the fields the
  request table reads. Prefer app-emitted `request` events: patched `fetch` can be frozen
  by bot managers, and a request that fired before the mapping loaded is gone, whereas a
  buffered `request` event is not.
- **Declare availability, degrade honestly.** Every capture handle reports `mode`; keep
  `{ webauthn, network }` availability flags in the coordinator context and read them at
  signal time. When WebAuthn capture is unavailable, a passkey attempt reports what was
  observed and nothing more: the submitted credential goes on `postResponse.start` as the
  fallback carrier, options observed on the wire go on `getOptions.finished` only, and no
  ceremony step is invented. Never report one credential twice across sources.
- **DOM last.** Reading rendered markup to infer screens, options or validation is what
  the data layer exists to avoid. Use the `input` reference the screen event carries; do
  not query for it.

### 5.6 Failure containment

The mapping runs inside a page it does not own. Every entry point — `consume`, every
fallback callback, every state method — is wrapped so a fault is logged and reported through
`tracker.telemetry` and never thrown into the app. A capture source that cannot attach is
reported once and the rest keeps working. Telemetry failure costs data, never a login.

## 6. Delivery

Delivery is a dimension of its own, independent of the shape: it decides where the mapping
bundle comes from, and it applies to Autocapture and the data layer alike. The shim and
the emitters stay in the app either way.

| Delivery                             | How                                                                                                                       | Who can change the mapping without an app release                                       |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| **Corbado script tag** (recommended) | A tiny stable loader script inserts an immutable, versioned mapping bundle from Corbado's CDN; a rollback re-points the loader | Corbado, live on the next page load — the customer never redeploys for a tracking change |
| Self-hosted                          | The mapping is the customer's own npm package (or a module in the app's repository), bundled and released with the app   | The customer, by bumping the dependency and releasing                                    |

Build the mapping so both are possible from one source: a self-contained entry that
exports `installObserveMapping()` for the self-hosted case and, for the script tag, a
loader command queue the app calls `init` / `setExperiments` / `destroy` on — exactly like
the analytics snippets it already runs; calls before the bundle arrives are replayed.
Corbado verifies a new mapping build from the outside before it ships, by injecting it
into the live page in a test browser and replaying recorded journeys against it. That
external test is only possible because the mapping imports nothing from the app.

Timing rule for both: the shim is at document start regardless of where the mapping
loads, so late installation loses nothing except time-critical fallback capture. A
WebAuthn ceremony that starts at page load (immediate mediation, auto-started conditional
UI) is observable only if the WebAuthn fallback attached before it — insert the loader as
early as the app allows when such ceremonies exist. Loading the mapping through a tag
manager is acceptable where tag governance requires it; it is late by construction.

## 7. Event catalog

| Event                                 | SDK call                                 | The mapping sends it when                                 |
| ------------------------------------- | ---------------------------------------- | --------------------------------------------------------- |
| `flow_started`                        | `flowStarted()`                          | an entry screen renders (flow table; one declared opener) |
| `flow_decided`                        | `flowDecided()`                          | a request result resolves an ambiguous entry              |
| `flow_finished`                       | `flowFinished()`                         | the terminal request succeeds, or a skip transition/choice |
| `flow_auto_finished`                  | `flowAutoFinished()`                     | a nested flow's terminal completes the parent             |
| `flow_reset`                          | `flowReset()`                            | rarely — explicit restart                                 |
| `auth_method_decision_started`        | `authMethodsDecisionStarted()`           | a `screen` is pushed (per presentation)                   |
| `auth_method_decision_finished`       | `authMethodsDecisionFinished()`          | a navigational `choice` (never for method choices)        |
| `subflow_started`                     | helper construction                      | input-bound: on `screen` with `input`; action-bound: on the method `choice` |
| `subflow_step_started/finished/error` | `op.<step>.start()/.finished()/.error()` | `request` phases, `ceremony` phases, `validation`         |
| `flow_enriched`                       | `setUser(user)`                          | `context.user`, inside the active flow                    |
| `conversion`                          | `conversion()`                           | business conversion outside auth (app emits a `context`-like custom event or calls the precision path) |

## 8. Taxonomy rules the mapping implements

### Flows

Standard flow names: `login`, `signup`, `recovery`, `enrollment`. Custom flows take a
freeform name (e.g. account renewal, reauthentication, transaction signing).

**Finishing.** A flow is explicitly finished only on success — or when it is explicitly
skipped. Do not model non-completion on the client: incompleteness is classified from the
absence of a `flow_finished`. Skipping is the one exception because it is semantically
different from abandoning (e.g. "continue as guest", or entering signup abandons an open
recovery): send `flowFinished({ flowName, explicitOutcome: "skipped" })`. If identity is known, record it separately with `setUser()`; this also applies to skips.

```typescript
tracker.flowStarted({ flowName: "login", touchpoint: "account" });
// ... success:
tracker.setUser({ userId: "usr_123", identifier: "max@example.com" });
tracker.flowFinished({ flowName: "login" });
```

When entry is ambiguous (combined login/signup form), start with
`flowNames: ["login", "signup"]` (+ optional `defaultFlowName`) and send
`flowDecided({ flowName })` once resolved.

**Nesting vs chaining.** Only `login` and `signup` can contain nested flows. A flow that
itself establishes the session (signup, recovery inside the login journey) nests inside
`login`; when the nested flow's own terminal fires, complete the parent with
`flowAutoFinished({ flowName: "login", finishedByFlowName: "signup" })`. A flow
that runs after the session already exists (typically enrollment prompted post-login) is
_chained_: a sibling flow started after the login finished, never nested.

Events always attribute to the innermost open flow. So when the user leaves a nested flow
without finishing it, close it explicitly (`explicitOutcome: "skipped"` is the usual fit —
e.g. entering signup skips an open recovery): it records the right outcome (skipped, not
abandoned) and keeps the parent's subsequent events out of the nested flow. This is the
one place where non-completion needs client help — in the default shape it is the flow
table's `skip` entries. The reverse also holds: never re-emit
the _outer_ flow's `flow_started` while a nested flow is open — the classifier reads it as
a restart and closes the nested flow as incomplete (see System context).

**Resets.** `flowReset()` exists but is rarely needed: whether a user restarted is
inferable later from revisited decisions and subflows. Don't emit it just to be tidy.

**Tags.** Flows are the natural carrier. Configuration tags (product, variant, device
class) ride `flow_started`; values only known on success ride `flow_finished`.
Tags are `Record<string, string>` passed as the second argument; last value per key wins
across a flow's events. Never put identity into tags — `userId`/`identifier` belong in
the user reference. Do not re-fire the opener from reactive config (store hydration,
feature flags) just to refresh its tags; late-known values go on `flow_finished`. In the
default shape tags arrive through `context.tags` and `screen.tags`; the coordinator holds
the latest values and stamps them where they belong.

### Decisions

Use `authMethodsDecisionStarted` / `authMethodsDecisionFinished` for **all** decisions.
Both accept method and freeform navigation options. The older `authDecisionStarted` /
`authDecisionFinished` methods are deprecated.

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
tracker.authMethodsDecisionStarted({
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
tracker.authMethodsDecisionFinished({
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

**Options on finish.** Send `decisionName` and `explicitDecisionValue` for a
navigational choice. Omit `options` to reuse the offer already sent with `started`.
The chosen value must belong to that offer.

| `options` on `finished` | Meaning                                                                                                                                                                                      |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Omitted or `null`       | Reuse the retained offer when its `decisionName` matches, preserving its options, timing, and occurrence history. Omit the field in TypeScript; the SDK type does not accept literal `null`. |
| Non-empty array         | Explicit offered choices. Use the same values and ordering as `started` to complete that occurrence. A different list can produce a separate decision occurrence.                            |
| `[]`                    | An explicit offer with no choices. It does not inherit options and cannot describe a valid selection.                                                                                        |

Keep option order stable: it distinguishes decision variants. Inheritance uses the
retained decision. If no matching
offer exists, classification reports `no_matching_offer`, ignores the finish, and keeps
an unrelated retained decision available. An inherited selection outside the offer reports
`result_not_offered` and creates no successful choice.

A method may already have resolved the retained offer before the user navigates away.
For example, an automatically started OTP attempt followed by "switch method" records
both choices in that offer's history. Finishing with the same value already resolved by
the method adds no duplicate choice. Continue to let subflows resolve method choices;
explicit finishes are for navigation.

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
time once and reuse it — the `screen` event's `ts` is that time. An option whose subflow
auto-starts on the screen still belongs in the option set — if a subflow can start on a
screen, its method option is part of that screen's options. Unresolved decisions classify
as incomplete.

**Option strings that subflows resolve.** The decision only resolves if the exact string
is present in `options`:

| Subflow (spec)                                                            | Option string                                                                                                                              |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| password-login (`password-known-identifier`)                              | `password-login-known-identifier`                                                                                                          |
| password-login (`password-with-identifier`)                               | `password-login-with-identifier`                                                                                                           |
| passkey-login (`passkey-known-identifier[-auto]`, `passkey-cui`, no spec) | `passkey-login-known-identifier`                                                                                                           |
| passkey-login (`passkey-no-identifier[-auto]`)                            | `passkey-login-no-identifier`                                                                                                              |
| passkey-login (`passkey-immediate`)                                       | resolves no option                                                                                                                         |
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

### Subflows

A subflow is one auth method attempt; creating the operation helper emits
`subflow_started`. When to create it depends on how the method is engaged:

- **Input-bound methods** (password, OTP, identifier, provide-data) start when the input
  renders — the field itself is the attempt surface, and the helper captures interaction
  on it. In the default shape: on the `screen` event, with its `input`.
- **Action-bound methods** (passkey button, social button, app confirmation) start on the
  action, not when the button becomes visible. In the default shape: on the method
  `choice`. A visible option is not an attempt; a helper
  created for a button nobody pressed yields an attempt without interaction — not counted
  for most types.

Construction always emits `subflow_started`; there is no opt-out. Never add
a manual `subflowStart()` on top of it. Repeated starts of the same subflow with nothing in
between are merged; don't guard against them. Do not emit `subflow_trigger`; it is
deprecated for the helpers used here and carries no classification value.

Instrumentation is additive by default: it observes the app's existing lifecycle and does
not add cancellation, timers, navigation rules or request signals of its own. Where a clean
attempt boundary genuinely needs a small restructuring (a single choke point for a
ceremony, a teardown hook), make it deliberately and call it out in the mapping notes.

```typescript
const op = tracker.passkeyLoginFullOperation({
    explicitSpecType: "passkey-known-identifier"
});
try {
    op.getOptions.start({});
    const options = await fetchAssertionOptions(email);
    op.getOptions.finished({ assertionOptions: JSON.stringify(options) });
} catch (e) {
    op.getOptions.error(e);
    return;
}
try {
    op.ceremony.start({});
    const response = await startWebAuthnAuthentication(options);
    op.ceremony.finished({ assertionResponse: JSON.stringify(response) });
} catch (e) {
    op.ceremony.error(e); // also the user cancelling the prompt
    return;
}
try {
    op.postResponse.start({});
    const result = await verifyOnServer(response);
    tracker.setUser({ userId: result.userId });
    op.postResponse.finished({});
} catch (e) {
    op.postResponse.error(e);
}
```

The passkey steps carry the WebAuthn payloads as JSON strings: for login,
`getOptions.finished` takes `assertionOptions` and `ceremony.finished` takes
`assertionResponse`; for enrollment the same steps take `attestationOptions` and
`attestationResponse`, and the enrollment `ceremony.start` additionally requires
`mediation` (`"conditional" | "optional" | "required"`). When the options are only known
at ceremony time (WebAuthn fallback), pass them on `ceremony.start` instead. When the
ceremony itself could not be observed, the submitted credential goes on
`postResponse.start` as the fallback carrier — never on both.

**Identifier-field Conditional UI** is not a passkey-login attempt. It belongs to the
provide-identifier helper's `cui` steps, resolves the same `identifier-email` option, and
runs alongside the manual identifier path:

```typescript
const op = tracker.provideIdentifierOperationFull({
    inputHtmlField: emailInput,
    explicitSpecType: "email"
});
// conditional request, started when the identifier surface renders:
op.cui.getOptions.start({ explicitSpecType: "passkey-cui" });
const options = await fetchConditionalOptions();
op.cui.getOptions.finished({ assertionOptions: JSON.stringify(options) });
op.cui.ceremony.start({});
try {
    const response = await startConditionalWebAuthn(options); // pending until picked or torn down
    op.cui.ceremony.finished({ assertionResponse: JSON.stringify(response) });
    op.cui.postResponse.start({});
    const result = await verifyOnServer(response);
    tracker.setUser({ userId: result.userId });
    op.cui.postResponse.finished({});
} catch (e) {
    // torn down because the user submitted the identifier or left: not an error
    if (!displacedByUser) op.cui.ceremony.error(e);
}
// manual path, on submit:
op.provideIdentifier.postResponse.start({});
```

**Read the installed package before applying a recipe.** Helper signatures can move between
releases.

| Helper (on tracker)                     | Subflow                            | Steps                                                                                                    | Spec types                                                                                            |
| --------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `provideIdentifierOperationFull(cfg?)`  | provide-identifier (+ passkey CUI) | `provideIdentifier.clientValidation` / `.postResponse`; `cui.getOptions` / `.ceremony` / `.postResponse` | `email`, `phone`; CUI: `passkey-cui`                                                                  |
| `passkeyLoginFullOperation(cfg?)`       | passkey-login                      | `getOptions`, `ceremony`, `postResponse`                                                                 | `passkey-known-identifier[-auto]`, `passkey-no-identifier[-auto]`, `passkey-cui`, `passkey-immediate` |
| `passkeyEnrollmentFullOperation(cfg?)`  | passkey-enrollment                 | `getOptions`, `ceremony`, `postResponse`                                                                 | `conditional`, `auto`, `manual` (legacy: `conditional-auto-manual`, `auto-manual`)                    |
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
mapping's job to make sure one of these attempts never runs spec-less end to end. The others tolerate
absence with a documented default (email/sms-otp assume the login variant, password-login
`password-known-identifier`, provide-identifier `email`, app-confirmation `qr-code`).
When a spec only becomes known mid-attempt, supply it on a step whose SDK payload
supports `explicitSpecType`.

**Continuing an attempt.** Recreating an operation after a redirect or environment
handoff emits another `subflow_started`. Supply the original matching spec type when
continuing the same attempt; a different known spec can split it into a separate attempt.
Start the destination flow before creating its operation.

**Input binding.** Where the helper supports it, pass the input element
(`inputHtmlField`) for input-related subflows — it enables interaction capture on the
field. Call `op.destroy()` when the surface unmounts (input-bound helpers and the passkey
helpers hold event listeners) — in the default shape, in the state's `exit()`.

**provide-data** covers form fields that request user data but map to no deeper subflow
concept (bank details, birth date, address...). One screen, one provide-data subflow on
the most important field; pass `fieldName` for the semantic name of what is collected.

**Parallel subflows** are fine as long as only one can plausibly receive interaction at a
time: a password field plus a passkey button on one screen is classifiable. A large form
where several tracked fields are filled and submitted together is not — model the
simplified version and track only the most important field (e.g. the password field on a
signup form).

### Step errors

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
  `expired`; CUI ceremony `cancel_detected`). In the default shape the `request` event's
  `code` and `message` are exactly this: the emitter names the observation, the mapping
  forwards it.

    ```typescript
    op.postResponse.start({});
    const body = await submitPassword(password);
    if (body.rejected) {
        // app's API refused the password — no exception in hand, name the observation:
        op.postResponse.error({
            code: "invalid_password",
            message: body.errorLabel
        });
        // ...or, where the helper types the code, compile-time checked:
        op.postResponse.errorTyped({ code: "invalid_password" });
    }
    // caught platform exception (e.g. a WebAuthn ceremony) — pass it raw, don't rewrap:
    op.ceremony.error(e);
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

### Event ordering

Ordering requirements are causal, not temporal:

1. `flow_started` before any event of that flow. A `flow_finished` or `flow_decided`
   without an open flow invalidates the session's classification — this is the unforgiving
   one. `flow_auto_finished` without an open flow of that name is not fatal, but it
   reconstructs a closed flow of that name — send it only for a parent that was started.
2. When a screen renders: decision `started` before creating operation helpers (decision
   before `subflow_started`).
3. Settle the previous screen before opening the next: a navigational choice's decision
   `finished` precedes the next screen's decision `started`.
4. Call `setUser()` while its intended flow is active, before `flowFinished()` or
   `flowAutoFinished()` closes it.

The backend orders by timestamp + emission sequence and repairs supported race patterns.
Use `explicitTimestamp` (on steps and decision `started`) when the semantic moment precedes
the tracking call — in the default shape, always: the data layer event's `ts` is the
semantic moment and the mapping may run later. Preserve the causal ordering above rather
than adding arbitrary delays; the app-side ordering invariants in 4.3 guarantee it.

### Identity observations

Call `tracker.setUser(user: UserReference)` when a user reference becomes known, **after
starting the intended flow and before finishing it**. The reference accepts `userId`,
`identifier`, and/or `crossEnvironmentTransactionID`. Transaction-only references are valid.
Use a stable `userId` to establish user identity; `identifier` alone does not reconcile
observations into an identified user.

Each call emits `flow_enriched` with
`data: { match: { flowType: "*", at: "during" }, expFol: true }` and the reference in the
`user` envelope. It matches the innermost active flow at emission time, regardless of flow
type. Matching has **no grace period**: after a nested recovery finishes, a subsequent
`setUser()` belongs to the still-open parent login, even if both calls share a timestamp.

Identity attribution follows these rules:

- The matched flow and its same-session subflows and decisions share the identified
  user, including steps earlier in that flow. Identification in a nested flow also identifies its
  enclosing flows in the same session. The latest identity observation belonging to a
  flow wins.
- Later flows can inherit the session's identity when they have no identity observation
  of their own. An observation in the parent after a child closes does not backfill
  that finished child.
- Calling outside an active flow reports `no_matching_flow` and cannot identify a
  finished flow. The observation can still affect later flows, so use `setUser()` only
  within the intended active flow.

Passing `{}` does not clear identity.

Legacy user-reference fields on flow finishes, conversions, and step options remain
supported but are deprecated. For new instrumentation, record identity separately with
`setUser()` within the active flow. When migrating a finish that carries identity, place
`setUser()` **before** the finish. In the default shape the coordinator holds the latest
`context.user` and calls `setUser()` when a flow it belongs to is open, and again right
before that flow's terminal.

### Cross-environment correlation

Events are correlated by a session id in local storage: everything sharing the JavaScript
process or local storage merges automatically — nothing to do. When a journey crosses a
boundary where local storage doesn't follow (another device, an iframe, some webview
setups), call `tracker.setUser({ crossEnvironmentTransactionID: id })` **on both ends** with the
same UUID. Start or continue the destination flow with `flowStarted` before calling
`setUser` there; correlation alone does not create an active flow. Continue the intended
innermost flow rather than re-announcing an outer flow. When recreating a subflow helper,
carry its original matching spec type as described under Continuing an attempt.

An identity observed in the destination can identify the explicitly continued flow.
The linked sessions are classified together. How the UUID travels is the app's choice —
for example, a magic link's query parameter or an existing transaction UUID the system
already propagates. In the default shape the destination page pushes
`context.user.crossEnvironmentTransactionID` after its entry screen.

## 9. Precision path (custom events)

Only when section 1 selected it. The rules of sections 2, 3 and 8 apply unchanged, but at
the call sites: every tracker call is written into the app at its semantic point. Keep the
blast radius small:

- Wrap `init()`/`getTracker()` in one module that lazily initializes, and guard every
  call site with `?.` so tracking cannot throw (see Setup).
- One declared opener per flow, in the flow's own entry component; every other component
  drops its signals when no flow is open. Keep a single module for the flow lifecycle even
  here — it is the one piece that must not be duplicated.
- Decisions on render with `explicitTimestamp`, helpers created on render (input-bound) or
  on the action (action-bound), steps around the app logic exactly as in section 8's samples.
- Document every lossy mapping in a short mapping note next to the wrapper module.

Every tracking correction on this path is an app release. Tell the user so when they choose it.

## 10. Setup

```bash
npm install @corbado/observe @corbado/autocapture
```

`projectId` and `apiBaseUrl` come from the Corbado console (https://app.corbado.com →
Observe → Settings). In the default shape the mapping's `installObserveMapping()` calls
`init()` once (section 5.2) after consent. For the precision path, wrap `init()`/`getTracker()`
in one module that lazily initializes, and guard every call site with `?.`:

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
like `"web"` when one project tracks several). Use `debug: true` while developing.
Experiments arrive through `context.experiments`; the mapping calls
`tracker.setExperiments(map)` so later events carry them.

## 11. Validating the implementation

Tracking cannot be proven from the app's own tests; the raw event series is what the
classifier sees. Validate in two loops.

**Inner loop — replay fixtures against the mapping.** The mapping's input is a
serializable event array, so record it once and replay it forever. A fixture is the
recorded data layer input plus the expected Observe series, in the same assertion format
Corbado's own scenario runners use: `ordered` is a subsequence, patterns match deeply and
partially, `forbidden` and `counts` catch what a subsequence would let through.

```json
{
    "id": "login-back-then-signup",
    "input": [
        { "event": "context", "touchpoint": "account" },
        { "event": "screen", "name": "identifier", "options": ["email", "signup-link", "google"], "ts": 1000 },
        { "event": "request", "name": "checkIdentifier", "id": "r1", "phase": "started", "ts": 1500 },
        { "event": "request", "name": "checkIdentifier", "id": "r1", "phase": "finished", "ts": 1700, "result": { "known": true } },
        { "event": "screen", "name": "password", "options": ["password", "passkey-button", "back"], "ts": 1710 },
        { "event": "choice", "screen": "password", "option": "back" },
        { "event": "screen", "name": "identifier", "options": ["email", "signup-link", "google"], "ts": 2500 },
        { "event": "choice", "screen": "identifier", "option": "signup-link" },
        { "event": "screen", "name": "signup-form", "options": ["password", "back"], "ts": 2600 },
        { "event": "request", "name": "completeSignup", "id": "r2", "phase": "started", "ts": 4000 },
        { "event": "context", "user": { "userId": "u_1" } },
        { "event": "request", "name": "completeSignup", "id": "r2", "phase": "finished", "ts": 4300 }
    ],
    "expect": {
        "ordered": [
            { "name": "flow_started", "data": { "flowName": "login" } },
            { "name": "auth_method_decision_finished", "data": { "decisionName": "post-identifier", "explicitDecisionValue": "back" } },
            { "name": "flow_started", "data": { "flowName": "signup" } },
            { "name": "flow_enriched" },
            { "name": "flow_finished", "data": { "flowName": "signup" } },
            { "name": "flow_auto_finished", "data": { "flowName": "login", "finishedByFlowName": "signup" } }
        ],
        "forbidden": [{ "name": "flow_reset" }],
        "counts": [{ "event": { "name": "auth_method_decision_started", "data": { "decisionName": "pre-identifier" } }, "min": 2, "max": 2 }]
    }
}
```

Run the mapping in a DOM test runner with the SDK's transport stubbed, feed `input`
through `window.corbadoDataLayer.push`, and assert on the batches the SDK produces.
Replace `input` element references in fixtures with elements created by the test. Record
new fixtures from real journeys by dumping the data layer array in the browser. Write one
fixture per representative journey before shipping, and one per bug afterwards.

**Outer loop — walk the app.** Pick a small set of journeys with decent coverage, write
down the event series each should produce in the notation of the worked example below,
have the developer run them with `debug: true` and hand back the console output: the SDK
logs every emitted event with its data. The Corbado Observe Debugger extension shows the
same stream as it leaves the browser. Read the series against the rules in this skill and
fix what deviates — in the mapping — before looking at dashboards.

## 12. Worked example

Identifier-first login where the user backs out of the password screen and then signs up
instead. The data layer input is the fixture in section 11; this is the Observe series a
correct mapping produces from it (`spec` = `explicitSpecType`):

```
flow_started            { flowName: login, touchpoint: account }        ← entry screen "identifier"
auth_method_decision_started  { pre-identifier, options: [identifier-email, switch-to-signup, social-google] }
subflow_started         { provide-identifier }                          ← screen carried the input
subflow_step_started    { provide-identifier, pi-post-response }        ← request checkIdentifier started
subflow_step_finished   { provide-identifier, pi-post-response }        ← request finished
                                                                        (resolves pre-identifier)
auth_method_decision_started  { post-identifier, options: [password-login-known-identifier,
                                passkey-login-known-identifier, back] } ← screen "password"
subflow_started         { password-login }                              ← screen carried the input
auth_method_decision_finished { post-identifier, explicitDecisionValue: back }   ← choice "back"
auth_method_decision_started  { pre-identifier, options: [...] }        ← screen "identifier" again: new occurrence
auth_method_decision_finished { pre-identifier, explicitDecisionValue: switch-to-signup }  ← choice "signup-link"
flow_started            { flowName: signup }                            ← entry screen "signup-form", nested in login
auth_method_decision_started  { signup-registration, options: [password-enrollment, back] }
subflow_started         { password-enrollment, spec: password-set }
subflow_step_started    { password-enrollment, post-response }          ← request completeSignup started
flow_enriched           data: { match: { flowType: "*", at: during }, expFol: true }, user: { userId }   ← context.user
subflow_step_finished   { password-enrollment, post-response }          (resolves signup-registration)
flow_finished           { flowName: signup }                            ← terminal request for signup
flow_auto_finished      { flowName: login, finishedByFlowName: signup } ← nested terminal completes the parent
```

Note what is absent: no decision `finished` for the method choices (their subflows resolve
them), no subflow finishes (the `post-response` steps carry the outcomes), and no explicit
incomplete/abandon events anywhere — had the user left mid-journey, the absence of the
finishes would have classified it. The second `pre-identifier` decision is deliberately a
second occurrence: the user genuinely revisited that checkpoint. And note what the app
never said: nothing about flows, decisions, subflows or Observe vocabulary — twelve pushes
in its own words, and the mapping did the rest.
