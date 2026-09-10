---
name: corbado-observe
description: Integrate Corbado Observe into a frontend application to measure
    authentication flows like login, signup, recovery or enrollment. Use when adding
    Corbado Observe, authentication analytics or passkey/login funnel tracking
    to an app.
---

# Corbado Observe integration

Corbado Observe is telemetry for authentication journeys. It never sits in the login path.
The application's journeys are mapped onto Observe's taxonomy of flows, decisions and
subflows, and a backend classifier turns the event stream into funnels and analytics.

Every Observe integration has the same two halves, whatever its shape:

- **Signal sources**: what the browser and the app reveal, that is screens and the controls
  on them, network exchanges, WebAuthn ceremonies and validation results.
- **One mapping**: the single place that turns those signals into Observe taxonomy calls
  through `@corbado/observe`.

The shapes differ in where the signals come from and who owns the mapping:

| Shape                                   | Signals                                                                                                                                                       | Mapping                                                                                              | App changes                                                |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| Autocapture                             | Browser surfaces only, read by Corbado's bundle via `@corbado/autocapture` (network, WebAuthn, DOM, existing low events)                                        | Built and maintained by Corbado, adjusted after app releases                                         | None. Corbado implements and maintains it                  |
| **Data layer + mapping** (default here) | The app pushes screen offers, outcomes and validation results. `@corbado/autocapture` in the app's own page pushes network and WebAuthn signals into the same layer | One central module in the structure Corbado uses for its own adapters. It can be replaced without touching the app | A stub, tagged controls, thin emitters and capture wiring   |
| Custom events (hand-written tracker calls) | Tracker calls written into the app's own code at the semantic points                                                                                          | Spread across the app's components                                                                   | Tracker calls at every semantic point                      |

Delivery, either a self-hosted package or a Corbado script tag (recommended), is a separate
dimension. It applies to Autocapture and to the data layer alike (section 6).

**Scope: this skill is for customers integrating from their own source. It implements the
data layer + mapping shape by default and uses custom events only under the conditions in
section 1.** Autocapture is implemented and maintained by Corbado and is not built with
this skill. All three shapes write into the same project, session and data model.
`@corbado/autocapture` is the capture library, `@corbado/observe` is the tracker SDK.

## 1. Decide the integration shape

First rule out Autocapture. A user who wants no source changes at all wants Autocapture: a
fully managed solution where Corbado derives everything from what is already there (API
calls, WebAuthn, fields and low events, existing component events) and adjusts the tracking
after larger releases. Corbado implements and maintains it. It is not built with this skill,
so stop and point the user to Corbado (support@corbado.com).

Otherwise default to the data layer + mapping. Use custom events (section 9) only in one of
these cases:

- The user explicitly asks for custom events or for individual hand-written tracker calls,
  for example a single conversion event outside the authentication journey.
- There is no structurally sound central place: the auth journey is spread over
  independently deployed surfaces without a shared script scope, or the app is so complex
  that routing its signals through one layer would be a larger change than instrumenting
  it directly.

When in doubt, ask before writing code. State the trade-off like this:

> Observe can be integrated three ways. **Data layer + mapping:** your screens get a data
> attribute per control, your code pushes a few events (screen shown, option chosen,
> validation failed) into a small in-page queue, network and WebAuthn are captured
> automatically, and one central module maps everything onto Observe. The benefits: no
> tracking calls scattered through components, the whole tracking model is readable in one
> place, Corbado can review and improve that module together with you, and new tracking
> logic can be tested by replaying recorded journeys. Before go-live the module can ship as
> your own package or from Corbado's CDN, so a tracking correction needs no app release.
> **Custom events:** tracker calls at every semantic point in your code. Every tracking
> correction is an app release, and there is no central place Corbado can improve with
> you. **Autocapture:** no code changes at all, fully managed by Corbado, set up with
> Corbado directly. Which do you want?

What each side owns in the default shape:

| The app keeps                                                                                                              | The mapping owns                                                                                        |
| -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| The `CorbadoObserve` stub, inserted first in `<head>`                                                                      | Taking over the stub and replaying its queue                                                            |
| Tagged controls and inputs, and emitters for screen offers, outcomes and client errors, keyed by the app's own screen names | Translation of screen names into decision names, the flow tables, subflow helpers and spec types        |
| Capture wiring: `captureNetwork` with the app's endpoint match and allowlist projectors, and `captureWebAuthn`             | The step mapping of every network exchange and ceremony, and every `@corbado/observe` call              |
| Lifecycle commands: `init` at document start, `setConsent`, `setUser`, `setExperiments` and `setTags`                       | Holding identity until consent, stamping tags and the consent state                                     |

**Hard rule:** the mapping module imports only its own contract types and `@corbado/observe`.
It never imports app internals and never touches browser APIs. This is what makes it
replaceable by an npm package, a CDN script or an injected build without touching the app,
and testable by replay. Screen names belong to the app. Option strings and everything
downstream belong to Observe.

## 2. System context: model for the classifier

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
- Decisions: every presented decision surfaces as its own occurrence. A later re-emission,
  with the same or with changed options, closes the open occurrence as incomplete and starts
  a new one. A revisited checkpoint is real information about the journey.

So flow-level events are emitted from one declared place per flow and never repeated
casually: the opener fires at the flow's own entry screens only, never from a nested
page "to make sure the parent is open". Subflow starts may repeat.
Decisions are emitted per _presentation_ (see Decisions). Prefer correctness by invariant
(proven execution order, one declared entry point per flow) over correctness by state.
In the default shape all tracking state lives in the mapping, in one owned place; the
app's emitters hold none. They report facts at the moment they happen.

## 3. Modeling method

Work the mapping in three passes, global concerns first. Mistakes in earlier passes cost
the most; later passes are local problems with small blast radius that may be solved more
pragmatically. Each pass produces one table of the mapping's `taxonomy.ts` (section 5).

**1. Flow boundaries.** For every flow, find the single best signal for when it starts,
when it finishes successfully and, where the app has one, when it is skipped. Do this
for all flows (top-level and nested) before anything else. The verifiable result of this
pass: the boundaries of what is tracked are exactly defined. This pass needs the most
care: a `flow_finished` without a matching open flow invalidates the whole
session's classification. Give each flow one declared opener; every other handler drops
its signals when no flow is open. In the default shape the opener is a screen: the flow
table names the entry screens of every flow, the request whose success finishes it, and
the screen transitions that mean a nested flow was skipped. Nothing about flows is emitted
by the app.

**2. Decision structure.** Assign every screen of the journey to a decision name (see
Decisions, usually fewer names than screens), then find the simplest way to determine the
selectable option set per screen. Option sets are a local problem, but look for one
mechanism that yields options globally if the app offers it (e.g. a server response that
already lists the rendered choices, or determining actual visibility via tagged elements
in the DOM). A screen can lead into the _same_ subflow through several controls (two
buttons that run the same ceremony, a primary tile plus an "other methods" list, a
prefilled versus typed identifier). That is one option and one subflow, since only one
option string can resolve; the difference is expressed through an explicit spec type where
the taxonomy has one, and otherwise modeled simplified: carry what differed as a tag
(typically on `flow_finished`) or accept the loss and document it. The screen table maps
each app screen name to its decision name; the controls on a screen carry their Observe
option strings directly in markup (section 4.3).

**3. Subflows.** Fill in one auth method attempt at a time. What matters is creating the
operation helper at the right moment (when the method appears or starts); then map the
app's signals onto the helper's steps where applicable. The network table maps each auth
endpoint (method and path) to a subflow step and names the projected body fields the mapping
reads to settle it.

Not every taxonomy detail needs instrumentation. Complexity trade-offs and mismatches
between the app and the taxonomy are legitimate. Prefer a clean
lossy mapping (documented) over a contorted complete one. Use subagents to verify the
integration against real journeys.

## 4. The Observe data layer (app side)

### 4.1 The `CorbadoObserve` stub

The data layer is `window.CorbadoObserve`, a command stub that works like an analytics data
layer and like Corbado's own loader snippets. Insert it verbatim, inline, as the first
script in `<head>`. It must come before any app code and must not sit behind a feature flag
or a consent gate:

```html
<script>
    (function (document, window) {
        var loaderUrl = ""; // rendered in for script-tag delivery; empty when the mapping is compiled in
        var commands = ["init", "setConsent", "setUser", "setExperiments", "setTags", "push", "destroy"];
        var stub, script, i;
        if (!window.CorbadoObserve) {
            stub = { q: [] };
            for (i = 0; i < commands.length; i++) {
                (function (name) {
                    stub[name] = function () { stub.q.push([name, Array.prototype.slice.call(arguments, 0)]); };
                })(commands[i]);
            }
            window.CorbadoObserve = stub;
        }
        if (!loaderUrl || window.__corbadoLoaderInjected) return;
        window.__corbadoLoaderInjected = true;
        script = document.createElement("script");
        script.async = true;
        script.src = loaderUrl;
        (document.head || document.documentElement).appendChild(script);
    })(document, window);
</script>
```

Every command is recorded as `[name, args]` on `q` until the mapping loads, takes the stub
over and replays the queue in arrival order. This buffer is why a mapping that loads late
loses nothing. The stub only records. Nothing leaves the page before the mapping runs.

| Command          | Arguments                                                          | Call when                                                                                   |
| ---------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `init`           | `{ projectId, apiBaseUrl, applicationId?, defaultTags?, debug? }`  | at document start, unconditionally, before consent is known (4.5)                           |
| `setConsent`     | `boolean`                                                          | consent is known or changes                                                                 |
| `setUser`        | `{ userId?, identifier?, crossEnvironmentTransactionID? }`         | identity becomes known, before the terminal request settles                                 |
| `setExperiments` | `Record<string, string>`                                           | A/B assignments resolve or change                                                           |
| `setTags`        | `Record<string, string>`                                           | a tag becomes known after `init`; last value per key wins, stamped on the next flow event   |
| `push`           | one data layer event (4.2)                                         | the signal happens                                                                          |
| `destroy`        | none                                                               | the surface is torn down for good. Consent changes do not call it                           |

Wrap `push` in a small helper so that emitters cannot throw (`contract.ts` declares the
`Window.CorbadoObserve` type):

```typescript
import type { DataLayerEvent } from "./observe-mapping/contract";

export const observe = (event: DataLayerEvent): void => {
    try {
        window.CorbadoObserve?.push(event);
    } catch {
        // telemetry never throws into the app
    }
};
```

### 4.2 Event contract: three families

Events are typed by their source. Two of the three families are the capture library's own
objects, so the mapping sees exactly what an Autocapture adapter sees.

| Family    | Kinds                               | Produced by                                                                     |
| --------- | ----------------------------------- | ------------------------------------------------------------------------------- |
| `dom`     | `screen`, `outcome`, `client-error` | the app's emitters (4.3)                                                        |
| `network` | `request`, `exchange`               | `captureNetwork` from `@corbado/autocapture`, wired in the app's page (4.4)     |
| `webApi`  | `webauthn` ceremony phases          | `captureWebAuthn` from `@corbado/autocapture`, wired in the app's page (4.4)    |

```typescript
import type { HttpExchange, HttpRequestStarted, WebAuthnCeremonyEvent } from "@corbado/autocapture";

export type DataLayerEvent =
    // dom: what the app rendered and what the user did on it
    | { type: "dom"; kind: "screen"; screen: string; options: string[]; timestamp: number;
        input?: HTMLInputElement; decision?: string; touchpoint?: string; tags?: Record<string, string> }
    | { type: "dom"; kind: "outcome"; screen: string; option: string; timestamp: number }
    | { type: "dom"; kind: "client-error"; screen: string; timestamp: number;
        errors: Array<{ field: string; code?: string; message?: string }> }
    // network: captureNetwork's objects, one event per phase
    | ({ type: "network"; kind: "request"; timestamp: number } & HttpRequestStarted)
    | ({ type: "network"; kind: "exchange"; timestamp: number } & HttpExchange)
    // webApi: captureWebAuthn's object; other web APIs may join this family later
    | ({ type: "webApi"; api: "webauthn"; timestamp: number } & WebAuthnCeremonyEvent);

// Narrowed views the mapping's states work with.
export type DomScreen = Extract<DataLayerEvent, { kind: "screen" }>;
export type DomOutcome = Extract<DataLayerEvent, { kind: "outcome" }>;
export type DomClientError = Extract<DataLayerEvent, { kind: "client-error" }>;
export type NetworkEvent = Extract<DataLayerEvent, { type: "network" }>;
export type WebAuthnEvent = Extract<DataLayerEvent, { type: "webApi" }>;

export type MappingOptions = {
    projectId: string;
    apiBaseUrl: string;
    applicationId?: string;
    defaultTags?: Record<string, string>;
    debug?: boolean;
};

declare global {
    interface Window {
        CorbadoObserve?: {
            init: (options: MappingOptions) => void;
            setConsent: (granted: boolean) => void;
            setUser: (user: { userId?: string; identifier?: string; crossEnvironmentTransactionID?: string }) => void;
            setExperiments: (assignments: Record<string, string>) => void;
            setTags: (tags: Record<string, string>) => void;
            push: (event: DataLayerEvent) => void;
            destroy: () => void;
        };
    }
}
```

`timestamp` is the epoch millisecond of the semantic moment: the render for a screen, the
click for an outcome, `startedAt` for a request, the settlement for an exchange. The mapping
passes it on as `explicitTimestamp`, so the mapping may run later without shifting anything.

### 4.3 DOM emitters: tagged controls and one emit site per screen

A screen offer is built from the markup. The app does not maintain a list of options in
code. Two attributes do the work:

```html
<button data-observe-decision-option="password-login-known-identifier">Log in</button>
<button data-observe-decision-option="passkey-login-known-identifier">Use a passkey</button>
<a data-observe-decision-option="recovery">Forgot password?</a>
<a data-observe-decision-option="back">Back</a>
<input type="password" data-observe-input />
```

- `data-observe-decision-option="<option>"` goes on every control whose visibility means
  that the option is offered. The value is the Observe option string. Method options use
  the exact strings from the table in section 8, because the classifier resolves nothing
  else. Navigational options are free-form names chosen by the naming rules in section 8
  and reused across screens. Tag the element that proves visibility; the click target can
  be a different element.
- `data-observe-input` goes on the screen's primary input. The first visible one becomes
  the helper's input for interaction capture.

One helper reads both and emits the offer. When there is nothing to decide, it emits
nothing:

```typescript
const isVisible = (el: Element) => {
    const style = getComputedStyle(el);
    return !(el as HTMLElement).hidden && style.display !== "none" && style.visibility !== "hidden"
        && el.getClientRects().length > 0;
};

/** Emit the offer a rendered screen makes. Returns the timestamp so a re-emit can reuse it. */
export function emitScreen(screen: string, root: ParentNode = document, timestamp = Date.now(),
    extra: { decision?: string; touchpoint?: string; tags?: Record<string, string> } = {}): number {
    const options = Array.from(root.querySelectorAll<HTMLElement>("[data-observe-decision-option]"))
        .filter(isVisible)
        .map((el) => el.dataset.observeDecisionOption!);
    const input = Array.from(root.querySelectorAll<HTMLInputElement>("input[data-observe-input]")).find(isVisible);
    if (options.length === 0 && !input) return timestamp;
    observe({ type: "dom", kind: "screen", screen, options, input, timestamp, ...extra });
    return timestamp;
}

export const emitOutcome = (screen: string, option: string) =>
    observe({ type: "dom", kind: "outcome", screen, option, timestamp: Date.now() });

export const emitClientErrors = (screen: string, errors: Array<{ field: string; code?: string; message?: string }>) => {
    if (errors.length) observe({ type: "dom", kind: "client-error", screen, errors, timestamp: Date.now() });
};
```

**When to emit the screen.** The screen drives the state machine, so its timing keeps the
mapping simple:

- Emit from one place per screen, after the render is complete. In a SPA this is the
  screen component's mount effect, delayed by one microtask so that the finished screen is
  visible. In a MPA it is the page load plus one emit per script-driven re-render.
- Emit after the previous screen's requests have settled and before the new screen starts
  anything Observe cares about, such as a ceremony or a request.
- Emit per presentation. A framework re-render alone is no new presentation. When a
  control appears later (a passkey button behind a capability check), emit again with the
  **same timestamp**. The mapping discards an unchanged set and replaces the open
  occurrence in place when the set changed. If unsure, emit. A missed offer costs a
  decision, a duplicate costs nothing.
- Name screens so that they read well in the mapping's screen table (`identifier`,
  `password`, `otp`, `signup-form`). A screen that is reused across stages (one TAN screen
  for login, 2FA and recovery) passes `decision` explicitly when the app knows the stage.
- Entry screens carry `touchpoint` and the entry tags.

```tsx
export function PasswordScreen() {
    const root = useRef<HTMLDivElement>(null);
    const offeredAt = useRef(0);
    useEffect(() => {
        offeredAt.current = Date.now();
        queueMicrotask(() => emitScreen("password", root.current!, offeredAt.current, { touchpoint: "account" }));
    }, []);
    // passkeyAvailable: the result of the app's own capability check, undefined until it resolved
    useEffect(() => {
        if (passkeyAvailable !== undefined) emitScreen("password", root.current!, offeredAt.current); // same timestamp
    }, [passkeyAvailable]);
    // ...
}
```

**Outcomes are resolved explicitly in the handler**, before the request the choice starts,
and for both kinds of option: a method (`emitOutcome("password", "passkey-login-known-identifier")`)
and a navigation (`emitOutcome("password", "recovery")`). Resolution follows what actually
happened. A multi-step choice resolves when it takes effect, and a guarded handler that
refuses resolves nothing.

**Client errors are reported by the validation pass itself**, one event per pass. It
carries every rejected field with the message the user saw and, where the browser produced
one, the native `ValidityState` key as `code` (`valueMissing`, `typeMismatch`). It never
carries a value. Server rejections need no event, they arrive on the wire.

### 4.4 Capture wiring: network and WebAuthn come from the browser

Network exchanges and WebAuthn ceremonies make up the majority of an integration's signals
and carry its error detail. They are captured. `captureNetwork` and `captureWebAuthn` run
in the app's page at document start and push their objects into the layer.

```typescript
import { captureNetwork, captureWebAuthn } from "@corbado/autocapture";
import { observe } from "./observe";
import { projectAuthRequest, projectAuthResponse } from "./observe-projectors";

// First module of the app bundle (or inline right after the stub on a MPA): before the first auth request.
captureNetwork({
    match: (url) => url.origin === location.origin && url.pathname.startsWith("/api/auth/"),
    bodyCapture: { request: projectAuthRequest, response: projectAuthResponse },
    onRequest: (request) => observe({ type: "network", kind: "request", timestamp: request.startedAt, ...request }),
    onExchange: (exchange) => observe({ type: "network", kind: "exchange", timestamp: Date.now(), ...exchange }),
});
const webauthn = captureWebAuthn({
    onEvent: (event) => observe({ type: "webApi", api: "webauthn", timestamp: Date.now(), ...event }),
});
// "standard" or "unavailable"; the mapping reads it for the fallback carrier rule (section 5.5)
window.CorbadoObserve?.setTags({ webauthnCapture: webauthn.mode });
```

Rules:

- **The projectors are the privacy boundary.** `bodyCapture` never reads a body without a
  projector. A projector returns only the fields the mapping's network table names: status
  codes, outcome flags, error codes, a prompt or step name. It never returns identifiers,
  passwords, one-time codes or raw bodies. A request projector that forwards a WebAuthn
  credential runs it through the package's sanitizers first (`sanitizeAssertionResponse`,
  `sanitizeCreationResponse` and the options counterparts).
- **One `captureNetwork` per page.** The package refuses to attach twice. Run the wiring in
  the first module the bundle evaluates, before bot managers or other scripts freeze
  `fetch`. On a MPA, inline it right after the stub.
- **Keep the patch as the source of network events.** Only when the customer refuses
  patching may the API client emit `network` events itself. They keep the same shape and
  carry all of `requestId`, `method`, `path`, `startedAt`, `status`, `ok`, `outcome` and
  `durationMs` plus the projected bodies. Write into the mapping notes what was lost: only
  what the client chose to project reaches the error analytics. Never run both.
- **WebAuthn has no app-side alternative.** Capture reports `mode: "unavailable"` only when
  an extension holds `navigator.credentials` in a form it declines to patch. The mapping
  then uses the fallback carrier rule in section 8. Push the handle's mode once as
  `setTags({ webauthnCapture: mode })` so that the mapping can read it.

### 4.5 Lifecycle: always on, consent as a signal

`init` runs at document start, unconditionally. Consent does not decide whether Observe
runs. It decides what is transmitted and how the backend processes the session:

- Call `setConsent(true)` as soon as consent is known. Until then the mapping transmits no
  identity: `setUser` is held and released into the open flow when consent arrives. The
  mapping stamps the consent state as a tag on every flow start so that the backend can
  treat the session accordingly.
- Call `setConsent(false)` on revocation. The mapping stops transmitting identity again.
- `destroy` is only for teardown, when a surface is removed for good. It is no consent
  reaction.

Whether recording into the in-page queue before consent is acceptable is the customer's
privacy call. The queue holds no identity until consent, and the projectors keep
identifiers out of network events. If even that is unacceptable, insert the stub after
consent and accept that earlier journeys are not recorded.

### 4.6 Bridging to the analytics data layer

The Observe data layer has the same mechanics as an analytics data layer and the same
event shape (one object with a type key and a flat payload), on purpose:

- **Mirror outward.** Where the customer wants auth events in their own analytics, push
  the same `dom` objects into their data layer as well. Do this from the emitter, never
  from the mapping.
- **Consume existing events.** Where the app already pushes auth facts into its analytics
  data layer, an emitter may translate those into `dom` events. Treat them as declared,
  optional signals whose ordering the app does not guarantee.
- **Keep `CorbadoObserve` separate from the tag manager's array.** The screen event still
  carries an input element, which tag managers mangle, and tag managers load late and
  behind consent gates. Once low events move into the layer as well, the queue holds no
  DOM references and can live anywhere a serializable data layer can.

## 5. The mapping (the central module)

### 5.1 Layout

```
observe-mapping/
  index.ts        installObserveMapping(): take over the stub, create the tracker on init, replay the queue
  contract.ts     DataLayerEvent, re-exported capture types, the Window.CorbadoObserve declaration; the app's only import
  taxonomy.ts     the three tables: flows, screens, network; all Observe vocabulary lives here
  coordinator.ts  flow lifecycle from the flow table; consent, identity and tags; routes events to the active screen state
  states/         one class per app screen: decision, helpers, steps
  steps.ts        settle() for network exchanges, ceremony() for WebAuthn events
```

Both of Corbado's production adapters have this shape. It keeps a mapping readable after a
year of changes. Corbado can supply a sample skeleton for the customer's stack, so ask
before inventing one. The contract types live inline for now. A shared package is planned.

### 5.2 Taking over the stub

```typescript
import { init, type CorbadoTracker, type UserReference } from "@corbado/observe";
import type { DataLayerEvent, MappingOptions } from "./contract";
import { Coordinator } from "./coordinator";

type Command = (...args: never[]) => unknown;
type Api = Record<"init" | "setConsent" | "setUser" | "setExperiments" | "setTags" | "push" | "destroy", Command>;

/** Runs when the module is evaluated: on import when compiled in, on load from the loader. */
export function installObserveMapping(): void {
    if (typeof window === "undefined" || window.top !== window.self) return; // frames don't own the journey
    let tracker: CorbadoTracker | undefined;
    let coordinator: Coordinator | undefined;
    const pending: DataLayerEvent[] = []; // pushed before init: held, replayed once the tracker exists
    const consume = (event: DataLayerEvent) => {
        try {
            coordinator?.handle(event);
        } catch {
            tracker?.telemetry("error", `mapping failed on ${event.type}/${"kind" in event ? event.kind : event.api}`);
        }
    };
    const api: Api = {
        init: (options: MappingOptions) => {
            if (tracker) return;
            tracker = init(options);
            coordinator = new Coordinator(tracker);
            pending.splice(0).forEach(consume);
        },
        setConsent: (granted: boolean) => coordinator?.setConsent(granted),
        setUser: (user: UserReference) => coordinator?.setUser(user),
        setExperiments: (assignments: Record<string, string>) => tracker?.setExperiments(assignments),
        setTags: (tags: Record<string, string>) => coordinator?.setTags(tags),
        push: (event: DataLayerEvent) => (coordinator ? consume(event) : pending.push(event)),
        destroy: () => {
            coordinator?.destroy();
            void tracker?.destroy();
            tracker = coordinator = undefined;
        },
    };
    const previous = window.CorbadoObserve as unknown as { q?: Array<[keyof Api, unknown[]]> } | undefined;
    window.CorbadoObserve = api as unknown as Window["CorbadoObserve"];
    for (const [name, args] of previous?.q?.splice(0) ?? []) {
        try {
            (api[name] as (...a: unknown[]) => unknown)?.(...args);
        } catch {
            tracker?.telemetry("error", `replay of ${name} failed`);
        }
    }
}

installObserveMapping();
```

The stub is replaced and every queued command is replayed in arrival order, so the
emission order is preserved whenever the mapping loads. Events pushed before `init` wait in
`pending`. No tracker exists until then.

### 5.3 Coordinator: flow lifecycle from tables

The coordinator owns flows, consent, identity and tags, and nothing else. Every flow event
is derived from the flow table, the way Corbado's own adapters do it:

```typescript
export const FLOWS = {
    // app screen → the flow it opens; nested flows open inside the innermost open login/signup
    entry: { identifier: "login", "signup-form": "signup", "recovery-email": "recovery", "enroll-passkey": "enrollment" },
    // network exchange → the flow its success finishes; `when` reads the projected response
    terminal: [
        { method: "POST", path: "/api/auth/session", flow: "login", when: (x) => x.responseBody?.loggedIn === true },
        { method: "POST", path: "/api/auth/signup", flow: "signup" },
        { method: "POST", path: "/api/auth/password-reset", flow: "recovery" },
        { method: "POST", path: "/api/auth/passkeys", flow: "enrollment" },
    ],
    // a screen whose render means these still-open nested flows were left: closed as skipped
    skip: { identifier: ["signup", "recovery"], password: ["signup", "recovery"] },
    // an outcome that skips the flow it is made in
    skipOutcome: { "enroll-passkey": ["not-now"] },
} as const;
```

Rules the coordinator enforces (section 8 has the classifier reasons):

- A `screen` with an entry mapping opens the flow if it is not already open, once, with
  the screen's `touchpoint`, the held tags and the consent tag. A repeated entry screen
  inside an open flow does not re-open it. An entry screen after the flow finished opens a
  new one.
- A screen in `skip` closes the listed nested flows with `explicitOutcome: "skipped"`
  before the screen's own state is entered. An outcome in `skipOutcome` closes its own flow.
- A terminal exchange (`ok` and `when` true) releases the held identity with `setUser()`
  when consent is granted, then calls `flowFinished()`. A nested flow's terminal also
  completes its parent with `flowAutoFinished({ flowName: parent, finishedByFlowName: nested })`.
  Call `tracker.flushKeepalive()` right after a terminal, because the app usually navigates
  away.
- An exchange whose projected body resolves an ambiguous entry (`{ known: true }` on a
  combined form) emits `flowDecided()`.
- Routing: a `screen` exits the current state, looks the screen up in the screen table,
  constructs its state and enters it. `outcome`, `client-error`, `network` and `webApi`
  events go to the active state, and `network` events are checked against the terminal
  table as well. A screen without a state maps to an `Unmapped` state that emits nothing
  and reports the gap through `tracker.telemetry("info", ...)`. An interface the mapping
  cannot name is a missing mapping and should be visible as one.

### 5.4 Screen states

One class per app screen. A state owns its decision, its operation helpers and the steps
its exchanges map to. Sketch of a post-identifier screen with password, passkey and
forgot-password:

```typescript
import type { CorbadoTracker, PasskeyLoginOperationFull, PasswordLoginOperationFull } from "@corbado/observe";
import type { DomScreen, DomOutcome, DomClientError, NetworkEvent, WebAuthnEvent } from "../contract";
import { SCREENS } from "../taxonomy"; // app screen → decision name
import { settle, ceremony } from "../steps";

export class PasswordScreen {
    private password?: PasswordLoginOperationFull;
    private passkey?: PasskeyLoginOperationFull;
    constructor(private readonly tracker: CorbadoTracker) {}

    enter(screen: DomScreen) {
        this.tracker.authMethodsDecisionStarted(
            { decisionName: screen.decision ?? SCREENS.password, options: screen.options },
            undefined,
            undefined,
            { explicitTimestamp: screen.timestamp },
        );
        // input-bound method: the attempt surface is the field, so the helper is created on render
        if (screen.input) {
            this.password = this.tracker.passwordLoginFullOperation({
                inputHtmlField: screen.input,
                explicitSpecType: "password-known-identifier",
            });
        }
    }

    outcome(e: DomOutcome) {
        switch (e.option) {
            case "passkey-login-known-identifier": // action-bound method: helper created on the action
                this.passkey = this.tracker.passkeyLoginFullOperation({ explicitSpecType: "passkey-known-identifier" });
                return;
            case "recovery": // navigational: finish explicitly; the next screen's decision follows
                this.tracker.authMethodsDecisionFinished({ decisionName: SCREENS.password, explicitDecisionValue: "recovery" });
                return;
        }
    }

    network(e: NetworkEvent) {
        switch (`${e.method} ${e.path}`) {
            case "POST /api/auth/password":
                return settle(this.password?.postResponse, e, {
                    success: (x) => x.responseBody?.status === "ok",
                    typed: { INVALID_CREDENTIALS: "invalid_password", LOCKED: "account_locked" },
                });
            case "POST /api/auth/passkeys/options":
                return settle(this.passkey?.getOptions, e); // the options themselves arrive with the ceremony start
            case "POST /api/auth/passkeys/verify":
                return settle(this.passkey?.postResponse, e);
        }
    }

    webApi(e: WebAuthnEvent) {
        if (e.kind === "authentication" && e.mediation !== "conditional") ceremony(this.passkey?.ceremony, e);
    }

    clientError(e: DomClientError) {
        if (e.errors.some((err) => err.field === "password"))
            this.password?.clientValidation.error({ name: "ClientValidationError", code: e.errors[0].code ?? "invalid" });
    }

    exit() {
        this.password?.destroy();
        this.passkey?.destroy();
    }
}
```

### 5.5 Settling steps from exchanges and ceremonies

Write these once in `steps.ts`; every state uses them:

- `settle(step, event, rules)`: a `request` event calls `step.start({}, { explicitTimestamp: startedAt })`.
  An `exchange` with `outcome !== "load"` is `step.error({ code: "transport_failed" })`.
  An HTTP failure or a projected rejection is `step.errorTyped({ code })` when `rules.typed`
  maps the server's code to a helper-typed one, else `step.error({ code, message })` with
  the server's raw label. Success (`ok` and `rules.success`, default `ok`) is
  `step.finished(rules.finished?.(exchange) ?? {})`. A response the rules cannot classify
  leaves the step open and goes to `tracker.telemetry` as a mapping gap. Do not guess a code.
- `ceremony(step, event)`: `started` calls `step.start({ assertionOptions: requestOptionsJson })`
  (enrollment: `attestationOptions` plus `mediation`), `completed` calls `step.finished`
  with `credentialJson`, `failed` calls `step.error(event.error ?? runtimeError(errorName))`
  (`runtimeError` wraps the DOM exception name in an `Error`) unless the ceremony was
  aborted because the user proceeded another way. One credential is
  reported once: keep the delivered credential keys per state and drop a duplicate that
  arrives from a second source.
- **When WebAuthn capture is unavailable** (the `webauthnCapture` tag says so), a passkey
  attempt reports only what was observed: the sanitized credential from the submission
  request goes on `postResponse.start` as the fallback carrier, options observed on the
  wire go on `getOptions.finished` only, and no ceremony step is invented.

### 5.6 Failure containment

The mapping runs inside a page it does not own. Every entry point (the replay, `consume`,
every state method) is wrapped, so a fault is logged and reported through
`tracker.telemetry` and never thrown into the app. A telemetry failure costs data. It never
costs a login.

## 6. Delivery

Delivery is a dimension of its own, independent of the shape. It decides where the mapping
bundle comes from, and it applies to Autocapture and to the data layer alike. The stub,
the tagged markup, the emitters and the capture wiring stay in the app in both cases, so
`@corbado/autocapture` is an app dependency in both modes and `@corbado/observe` only
when the mapping is compiled in.

| Delivery                             | How                                                                                                                                                         | Who can change the mapping without an app release                                       |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| **Corbado script tag** (recommended) | The stub is issued with a loader URL; the loader inserts an immutable, versioned mapping bundle from Corbado's CDN; a rollback re-points the loader          | Corbado, live on the next page load. The customer does not redeploy for a tracking change |
| Self-hosted                          | The mapping is the customer's own npm package or a module in the app's repository, bundled and released with the app. Or it is the same IIFE on the customer's own CDN behind their own loader | The customer, by bumping the dependency and releasing, or by re-pointing their loader   |

**Start local, switch later.** A new integration starts compiled in, because no Corbado-hosted
bundle exists for the app yet, and switches delivery without touching emitters:

1. Compiled in: `npm install @corbado/observe @corbado/autocapture`, the stub inline in
   `<head>` with an empty loader URL, the capture wiring and `import "./observe-mapping"`
   first thing in the app's entry, `CorbadoObserve.init(...)` right after.
2. Script tag: build the same `observe-mapping/` entry as a self-contained IIFE with
   `@corbado/observe` bundled, host it behind a loader (Corbado's CDN, set up together with
   Corbado, or the customer's own), remove the import and the `@corbado/observe`
   dependency, and issue the stub with the loader URL. Markup, emitters, capture wiring
   and every command call stay as they are.

Corbado verifies a new mapping build from outside before it ships: it injects the build
into the live page in a test browser and replays recorded journeys against it. This works
because the mapping imports nothing from the app.

Timing rule for both: the stub and the capture wiring are at document start regardless of
where the mapping loads, so a late mapping loses nothing. Every request and ceremony is
already in the queue. Loading the mapping through a tag manager is acceptable where tag
governance requires it. It is late by nature, and that is fine here.

## 7. Event catalog

| Event                                 | SDK call                                 | The mapping sends it when                                                                    |
| ------------------------------------- | ---------------------------------------- | -------------------------------------------------------------------------------------------- |
| `flow_started`                        | `flowStarted()`                          | an entry screen's offer arrives (flow table; one declared opener)                            |
| `flow_decided`                        | `flowDecided()`                          | an exchange's projected body resolves an ambiguous entry                                     |
| `flow_finished`                       | `flowFinished()`                         | the terminal exchange succeeds, or a skip transition or skip outcome                         |
| `flow_auto_finished`                  | `flowAutoFinished()`                     | a nested flow's terminal completes the parent                                                |
| `flow_reset`                          | `flowReset()`                            | rarely, only for an explicit restart                                                         |
| `auth_method_decision_started`        | `authMethodsDecisionStarted()`           | a `screen` offer (per presentation)                                                          |
| `auth_method_decision_finished`       | `authMethodsDecisionFinished()`          | a navigational `outcome` (method outcomes are resolved by their subflows)                    |
| `subflow_started`                     | helper construction                      | input-bound: on a `screen` offer with `input`; action-bound: on the method `outcome`         |
| `subflow_step_started/finished/error` | `op.<step>.start()/.finished()/.error()` | `network` request and exchange phases, `webApi` ceremony phases, `client-error`              |
| `flow_enriched`                       | `setUser(user)`                          | the `setUser` command, once consent is granted, inside the active flow                       |
| `conversion`                          | `conversion()`                           | business conversion outside auth (a hand-written tracker call)                               |

## 8. Taxonomy rules the mapping implements

### Flows

Standard flow names: `login`, `signup`, `recovery`, `enrollment`. Custom flows take a
freeform name (e.g. account renewal, reauthentication, transaction signing).

**Finishing.** A flow is explicitly finished only on success, or when it is explicitly
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
without finishing it, close it explicitly (`explicitOutcome: "skipped"` is the usual fit,
e.g. entering signup skips an open recovery): it records the outcome as skipped and keeps
the parent's subsequent events out of the nested flow. This is the one place where
non-completion needs client help. In the default shape it is the flow table's `skip`
entries. The reverse also holds: do not re-emit the _outer_ flow's `flow_started` while a
nested flow is open. The classifier reads it as a restart and closes the nested flow as
incomplete (see System context).

**Resets.** `flowReset()` exists but is rarely needed: whether a user restarted is
inferable later from revisited decisions and subflows. Don't emit it just to be tidy.

**Tags.** Flows are the natural carrier. Configuration tags (product, variant, device
class) ride `flow_started`; values only known on success ride `flow_finished`.
Tags are `Record<string, string>` passed as the second argument; last value per key wins
across a flow's events. Do not put identity into tags. `userId` and `identifier` belong in
the user reference. Do not re-fire the opener from reactive config (store hydration,
feature flags) just to refresh its tags; late-known values go on `flow_finished`. In the
default shape tags arrive through `init` (`defaultTags`), `setTags` and `screen.tags`;
the coordinator holds the latest values and stamps them where they belong.

### Decisions

Use `authMethodsDecisionStarted` / `authMethodsDecisionFinished` for **all** decisions.
Both accept method and freeform navigation options. The older `authDecisionStarted` /
`authDecisionFinished` methods are deprecated.

**Two kinds of options, one option set.** A screen's option set usually mixes both:

- **Method options.** The user chooses to attempt an auth method: start typing a
  password, click the passkey button. These use the predefined option strings (below) and
  are _never_ finished explicitly: the subflow that follows resolves the decision in
  classification.
- **Navigational/routing options.** The user wants a different option set: switch
  verification method, change identifier, back, create account, enter recovery. Freeform
  names; finish explicitly with `explicitDecisionValue` the moment the choice is made,
  typically followed by the next screen's decision `started`.

Realistic logins have many navigational options. They are the adaptive, per-application
part of the model and deserve the same care as the method options. Name them for reuse across decisions
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

**Decision names are checkpoints.** A decision name is a semantic unit of the journey,
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
| Omitted or `null`       | Reuse the retained offer when its `decisionName` matches, preserving its options, timing and occurrence history. Omit the field in TypeScript; the SDK type does not accept literal `null`. |
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

A decision occurrence is a _presentation to the user_. A framework render on its own is
no presentation. Re-send `started`
whenever the checkpoint is re-presented or its options change. Each presentation becomes
its own occurrence and the superseded one closes as incomplete, which is exactly what a
revisited checkpoint should look like. An identical offer with no user action or
navigation in between is the same presentation and must not be re-emitted (framework
re-renders, route remounts, hydration); a click-driven decision is always a new
presentation. Engaging a method resolves the decision regardless of how the attempt ends,
so a failed attempt on an unchanged screen is a retry inside the same occurrence and no
reason to re-emit `started`. When the option set depends on an async capability check
(conditional mediation, platform authenticator availability), emit `started` synchronously
on render with `explicitTimestamp` set to the render time, and re-emit with the final
options and the _same_ timestamp once the check resolves: an identical timestamp replaces
the open occurrence's options in place instead of opening a new one. Capture the render
time once and reuse it: the `screen` event's `timestamp` is that time. An option whose
subflow auto-starts on the screen still belongs in the option set: if a subflow can start on a
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
| provide-identifier                                                        | `identifier-email` (also when its CUI part completes; a CUI ceremony torn down by the identifier submit is neutral, no error and no abandon) |
| provide-data                                                              | `provide-data`                                                                                                                             |
| social-login                                                              | `social-google` / `social-apple` / `social-facebook` / `social-other`                                                                      |
| app-confirmation                                                          | `qr-code` (dedicated QR screen) or `app-confirmation`                                                                                      |
| totp (low-level)                                                          | `totp` / `totp-enrollment`                                                                                                                 |

("fallback" = the subflow first tries the spec-typed string, then the generic one. Put
whichever your option set naturally distinguishes.)

### Subflows

A subflow is one auth method attempt; creating the operation helper emits
`subflow_started`. When to create it depends on how the method is engaged:

- **Input-bound methods** (password, OTP, identifier, provide-data) start when the input
  renders: the field itself is the attempt surface and the helper captures interaction
  on it. In the default shape: on the `screen` event, with its `input`.
- **Action-bound methods** (passkey button, social button, app confirmation) start on the
  action. A visible button is no attempt yet. In the default shape: on the method
  `outcome`. A helper created for a button nobody pressed yields an attempt without
  interaction, which is not counted for most types.

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
`postResponse.start` as the fallback carrier. Do not put it on both.

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
almost every subflow (`exchangeCode` for social, `ceremony` for app-confirmation). Track
it always. Earlier and utility steps are enrichment you may skip when the effort outweighs
the value, with one exception: the WebAuthn `ceremony` steps of the passkey subflows.
Track those whenever passkeys are in play; ceremony start/finished/error is what powers
all passkey-related analytics (engagement, cancellation, ceremony errors and durations)
and none of it is recoverable from `postResponse` alone. A completed ceremony without a
`postResponse` still classifies as incomplete,
because only the backend confirmation proves the method worked. (The low-level
`trackSubflowError` carries no outcome semantics. Step errors are the intended channel, so
do not use it.)

On failure, call `.error(e)` on the step that failed and stop; a retry is simply new step
events. See Step errors below for what to put into them.

**Spec types.** Supply `explicitSpecType` on the constructor whenever known. For
passkey-login, passkey-enrollment, password-enrollment, provide-data, email-link and
social-login a spec must eventually arrive on _some_ event of the attempt. The
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
(`inputHtmlField`) for input-related subflows. It enables interaction capture on the
field. Call `op.destroy()` when the surface unmounts (input-bound helpers and the passkey
helpers hold event listeners), in the default shape in the state's `exit()`.

**provide-data** covers form fields that request user data but map to no deeper subflow
concept (bank details, birth date, address...). One screen, one provide-data subflow on
the most important field; pass `fieldName` for the semantic name of what is collected.

**Parallel subflows** are fine as long as only one can plausibly receive interaction at a
time: a password field plus a passkey button on one screen is classifiable. A large form
where several tracked fields are filled and submitted together is not. Model the
simplified version and track only the most important field (e.g. the password field on a
signup form).

### Step errors

Error tracking is an optional investment tier. Classification never depends on it. An
attempt that just stops already classifies as incomplete; an explicit step error is a
_different_ outcome (`<step>-error` vs `<step>-incomplete`), so errors add diagnostic
depth on top of a classification that is already correct. Map them to the depth the customer wants error analytics.

What makes the investment pay: the backend groups every reported error by its exact
signature (subflow type, step, code, message, spec type, latency bucket) into error
"flavours", which are then curated into named errors with impact analysis. Nothing is
dropped or bucketed as "other"; whatever the client sends is the raw material for
grouping. That yields four rules:

- **Platform errors go in raw.** For failures the platform produces (WebAuthn and browser
  exceptions, OS credential sheets), `.error(e)` with the caught exception is the right
  call: the platform's own vocabulary is already bounded (a cancelled or failed ceremony
  comes in only a handful of error names) and groups well as-is. Never withhold a real
  failure because it has no curated code.
- **The application's own errors deserve a deliberate shape.** Where the failure comes
  from the app's API or the transport/wire layer, decide explicitly what to send: a code
  naming what the client _observed_ (`invalid_password`,
  `invalid_otp`, `transport_failed`, `http_error`, `process_terminated`), reused where
  the same observation recurs across steps and platforms, with the server's raw error
  label as the message. Do not encode an interpretation of the failure. The shape is
  untyped, so get it exactly right: pass a plain
  `{ code, message }` object to `.error()`. It nests both where classification reads
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
        // app's API refused the password, no exception in hand, name the observation:
        op.postResponse.error({
            code: "invalid_password",
            message: body.errorLabel
        });
        // ...or, where the helper types the code, compile-time checked:
        op.postResponse.errorTyped({ code: "invalid_password" });
    }
    // caught platform exception (e.g. a WebAuthn ceremony): pass it raw, do not rewrap:
    op.ceremony.error(e);
    ```

- **Keep volatile tokens out of messages.** Request ids, timestamps and user data
  fragment the flavour grouping. Per-occurrence tokens are the problem. The number of
  distinct errors the app genuinely has is no problem.
- **No fallback codes.** A response you cannot confidently classify is neither success
  nor failure: leave the step open (it classifies incomplete) and surface the mapping gap
  through your own diagnostics instead. Not proving success is not the same as failing. A
  guessed code pollutes exactly the analytics errors exist to feed.
- **User cancellation is an error on the step that observed it.** A dismissed passkey
  prompt is a `ceremony` error; the raw browser error is fine. The exception: an
  auto-offered method torn down because the user proceeded with another (e.g. a CUI
  request aborted by a password submit) is not an error.

### Event ordering

Ordering requirements follow cause and effect. They do not depend on wall-clock time:

1. `flow_started` before any event of that flow. A `flow_finished` or `flow_decided`
   without an open flow invalidates the session's classification. This is the one rule
   without any tolerance. `flow_auto_finished` without an open flow of that name is not fatal, but it
   reconstructs a closed flow of that name. Send it only for a parent that was started.
2. When a screen renders: decision `started` before creating operation helpers (decision
   before `subflow_started`).
3. Settle the previous screen before opening the next: a navigational choice's decision
   `finished` precedes the next screen's decision `started`.
4. Call `setUser()` while its intended flow is active, before `flowFinished()` or
   `flowAutoFinished()` closes it.

The backend orders by timestamp + emission sequence and repairs supported race patterns.
Use `explicitTimestamp` (on steps and decision `started`) when the semantic moment precedes
the tracking call. In the default shape this is always the case: the data layer event's
`timestamp` is the semantic moment and the mapping may run later. Preserve the causal ordering above rather
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

Legacy user-reference fields on flow finishes, conversions and step options remain
supported but are deprecated. For new instrumentation, record identity separately with
`setUser()` within the active flow. When migrating a finish that carries identity, place
`setUser()` **before** the finish. In the default shape the coordinator holds the latest
`setUser` command and calls `setUser()` once consent is granted and a flow it belongs to is
open, and again right before that flow's terminal.

### Cross-environment correlation

Events are correlated by a session id in local storage: everything sharing the JavaScript
process or local storage merges automatically, nothing to do. When a journey crosses a
boundary where local storage doesn't follow (another device, an iframe, some webview
setups), call `tracker.setUser({ crossEnvironmentTransactionID: id })` **on both ends** with the
same UUID. Start or continue the destination flow with `flowStarted` before calling
`setUser` there; correlation alone does not create an active flow. Continue the intended
innermost flow. Do not re-announce an outer flow. When recreating a subflow helper,
carry its original matching spec type as described under Continuing an attempt.

An identity observed in the destination can identify the explicitly continued flow.
The linked sessions are classified together. How the UUID travels is the app's choice,
for example a magic link's query parameter or an existing transaction UUID the system
already propagates. In the default shape the destination page calls
`CorbadoObserve.setUser({ crossEnvironmentTransactionID })` after its entry screen.

## 9. Custom events: hand-written tracker calls

Only when section 1 selected it. The rules of sections 2, 3 and 8 apply unchanged, but at
the call sites: every tracker call is written into the app at its semantic point, and every
call site has to follow the taxonomy rules on its own. Keep the blast radius small:

- Wrap `init()`/`getTracker()` in one module that lazily initializes, and guard every
  call site with `?.` so tracking cannot throw (see Setup).
- One declared opener per flow, in the flow's own entry component; every other component
  drops its signals when no flow is open. Keep a single module for the flow lifecycle even
  here. It is the one piece that must not be duplicated.
- Decisions on render with `explicitTimestamp`, helpers created on render (input-bound) or
  on the action (action-bound), steps around the app logic exactly as in section 8's samples.
- Document every lossy mapping in a short mapping note next to the wrapper module.

Every tracking correction on this path is an app release. Tell the user so when they choose it.

## 10. Setup: project, credentials and tools

The mapping needs two public values, `projectId` and `apiBaseUrl`. Never ask for, handle
or store an API key. The SDK does not use one, and the CLI keeps its own in the OS keychain.

**With the Corbado Observe CLI (macOS on Apple Silicon).** Prefer this. It pairs the project
without copying anything by hand and it is the verification loop in section 11.

1. Install: `brew install --cask corbado/tap/corbado`.
2. Pair: `corbado switch --add`. The CLI prints a pairing URL and a short confirmation code,
   opens the browser and waits. In the console the user signs in, or creates an account and
   a project (**Create a new project**, project type **Observe**, any name), then confirms
   the code on the CLI pairing page under **Observe → Settings → API keys**. The key lands
   in the keychain. Nothing is pasted anywhere.
3. Verify the pairing: `corbado switch --whoami` must report `match: true`.
4. Read the two values: `corbado switch --list` prints `projectId` and `apiBaseUrl` for
   every paired project and marks the active one. Use `apiBaseUrl` as printed. The
   `--print-api-base-url` variant prints the CLI's own versioned prefix, which is the wrong
   value for the SDK.
5. Run `corbado guide` once. It is the CLI's own playbook.

**Without the CLI** (no macOS, no Homebrew, or the user prefers the console) everything is
in the management console:

- Sign in at https://app.corbado.com. No project yet: **Create a new project**, project
  type **Observe**, any name. A demo project is fine for a first integration.
- **Observe → Settings → General** shows **Project ID** and **API Base URL** as copy fields:
  `https://app.corbado.com/<projectId>/observe/settings/general`.
- **Observe → Settings → Origins → Create origin** for every origin the auth journey runs on:
  `https://app.corbado.com/<projectId>/observe/settings/origins`.
- Verification pages, used in section 11: **Observe → Debugging → Integration**
  (`/observe/debugging/integration`), **Observe → Debugging → User Search**
  (`/observe/debugging/user-search`), **Observe → Analytics → Funnel**
  (`/observe/analytics/funnel?diagram=login`).

Then install the packages and initialize through the stub:

```bash
npm install @corbado/observe @corbado/autocapture
```

```typescript
// right after the capture wiring and the mapping import, at document start
CorbadoObserve.init({ projectId: "pro-XXX", apiBaseUrl: "https://api.cloud.corbado.io", applicationId: "web", debug: true });
```

Use `debug: true` while developing. The SDK then logs every emitted event and the session id
to the console. Keep environments in separate projects.

For custom events, wrap `init()`/`getTracker()` in one module that lazily initializes
and guard every call site with `?.`:

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

## 11. Validating the implementation

Tracking cannot be proven from the app's own tests. The raw event series is what the
classifier sees. Validate in three loops, from the inside out.

**Replay fixtures against the mapping.** The mapping's input is the stub's queue, a
serializable array of `[command, args]` that carries everything: commands, screens,
outcomes, exchanges and ceremonies. Record it once by dumping `CorbadoObserve.q` before the
mapping takes over (or by wrapping `push` in the test build) and replay it as often as you
like. A fixture is that queue plus the expected Observe series, in the assertion format
Corbado's own scenario runners use: `ordered` is a subsequence, patterns match deeply and
partially, and `forbidden` and `counts` catch what a subsequence would let through.

```json
{
    "id": "login-back-then-signup",
    "queue": [
        ["init", [{ "projectId": "pro-test", "apiBaseUrl": "https://api.cloud.corbado.io", "applicationId": "web" }]],
        ["setConsent", [true]],
        ["push", [{ "type": "dom", "kind": "screen", "screen": "identifier", "options": ["identifier-email", "switch-to-signup", "social-google"], "timestamp": 1000, "touchpoint": "account" }]],
        ["push", [{ "type": "network", "kind": "request", "requestId": "r1", "transport": "fetch", "method": "POST", "url": "https://app.example/api/auth/identifier", "path": "/api/auth/identifier", "startedAt": 1500, "timestamp": 1500 }]],
        ["push", [{ "type": "network", "kind": "exchange", "requestId": "r1", "transport": "fetch", "method": "POST", "url": "https://app.example/api/auth/identifier", "path": "/api/auth/identifier", "status": 200, "ok": true, "outcome": "load", "durationMs": 200, "responseBody": { "known": true }, "timestamp": 1700 }]],
        ["push", [{ "type": "dom", "kind": "screen", "screen": "password", "options": ["password-login-known-identifier", "passkey-login-known-identifier", "back"], "timestamp": 1710 }]],
        ["push", [{ "type": "dom", "kind": "outcome", "screen": "password", "option": "back", "timestamp": 2400 }]],
        ["push", [{ "type": "dom", "kind": "screen", "screen": "identifier", "options": ["identifier-email", "switch-to-signup", "social-google"], "timestamp": 2500 }]],
        ["push", [{ "type": "dom", "kind": "outcome", "screen": "identifier", "option": "switch-to-signup", "timestamp": 2550 }]],
        ["push", [{ "type": "dom", "kind": "screen", "screen": "signup-form", "options": ["password-enrollment", "back"], "timestamp": 2600 }]],
        ["push", [{ "type": "network", "kind": "request", "requestId": "r2", "transport": "fetch", "method": "POST", "url": "https://app.example/api/auth/signup", "path": "/api/auth/signup", "startedAt": 4000, "timestamp": 4000 }]],
        ["setUser", [{ "userId": "u_1" }]],
        ["push", [{ "type": "network", "kind": "exchange", "requestId": "r2", "transport": "fetch", "method": "POST", "url": "https://app.example/api/auth/signup", "path": "/api/auth/signup", "status": 200, "ok": true, "outcome": "load", "durationMs": 300, "responseBody": { "created": true }, "timestamp": 4300 }]]
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

Run the mapping in a DOM test runner with the SDK's transport stubbed, seed a stub whose
`q` is the fixture's `queue`, install the mapping and assert on the batches the SDK
produces. Replace `input` element references in fixtures with elements created by the
test. Write one fixture per representative journey before shipping and one per bug
afterwards.

**Walk the app.** Pick a small set of journeys with decent coverage and write down the
event series each should produce, in the notation of the worked example below. Run them
with `debug: true`. The SDK logs every emitted event with its data and the session id, and
the Corbado Observe Debugger extension shows the same stream as it leaves the browser.
Check that each journey produces exactly one flow start, one decision per presented
screen, the expected steps and a finish. Cancel a passkey dialog once and confirm that it
shows up as an incomplete journey. Fix what deviates, in the mapping or in the markup,
before looking at dashboards.

**Check against the backend.** Raw arrival is not classification yet. With the CLI, using
the session id from the debug log:

```bash
SINCE=$(( $(date +%s) * 1000 - 600000 ))                                   # last 10 minutes, epoch ms
corbado events-feed --ingested-after $SINCE --session-id <session-uuid> --limit 500   # arrivals; watch `classified`
corbado classify <session-uuid>                                            # classify now instead of waiting
corbado classification-errors --created-after $SINCE --session-id <session-uuid>     # why something did not classify
corbado session <session-uuid>                                             # flows, decisions and subflows as classified
corbado integration-stats && corbado integration-status                    # per-type enablement and 24h error counts
```

Without the CLI, in the console under **Observe → Debugging → Integration**: search the
session id, read the **Ingested events** tab and its **Classified** / **Pending** badges,
press **Process** (it classifies the visible unclassified sessions, updates the integration
status and precalculates the time series), then read the **Classification errors** tab.
**Observe → Debugging → User Search** reconstructs the journey, and **Observe → Analytics →
Funnel** shows it once precalculation has run. Every classification error names the rule
in section 8 that was broken.

## 12. Worked example

Identifier-first login where the user backs out of the password screen and then signs up
instead. The stub queue is the fixture in section 11; this is the Observe series a correct
mapping produces from it (`spec` = `explicitSpecType`):

```
flow_started            { flowName: login, touchpoint: account, tags: { consent: granted } }   ← entry screen "identifier"
auth_method_decision_started  { pre-identifier, options: [identifier-email, switch-to-signup, social-google] }
subflow_started         { provide-identifier }                          ← the offer carried the input
subflow_step_started    { provide-identifier, pi-post-response }        ← POST /api/auth/identifier request
subflow_step_finished   { provide-identifier, pi-post-response }        ← exchange ok, { known: true }
                                                                        (resolves pre-identifier)
auth_method_decision_started  { post-identifier, options: [password-login-known-identifier,
                                passkey-login-known-identifier, back] } ← screen "password"
subflow_started         { password-login }                              ← the offer carried the input
auth_method_decision_finished { post-identifier, explicitDecisionValue: back }   ← outcome "back"
auth_method_decision_started  { pre-identifier, options: [...] }        ← screen "identifier" again: new occurrence
auth_method_decision_finished { pre-identifier, explicitDecisionValue: switch-to-signup }  ← outcome
flow_started            { flowName: signup }                            ← entry screen "signup-form", nested in login
auth_method_decision_started  { signup-registration, options: [password-enrollment, back] }
subflow_started         { password-enrollment, spec: password-set }
subflow_step_started    { password-enrollment, post-response }          ← POST /api/auth/signup request
flow_enriched           data: { match: { flowType: "*", at: during }, expFol: true }, user: { userId }   ← setUser, consent granted
subflow_step_finished   { password-enrollment, post-response }          (resolves signup-registration)
flow_finished           { flowName: signup }                            ← terminal exchange for signup
flow_auto_finished      { flowName: login, finishedByFlowName: signup } ← nested terminal completes the parent
```

Note what is absent: no decision `finished` for the method choices (their subflows resolve
them), no subflow finishes (the `post-response` steps carry the outcomes) and no explicit
incomplete or abandon events anywhere. Had the user left mid-journey, the missing finishes
would have classified it. The second `pre-identifier` decision is deliberately a second
occurrence, because the user genuinely revisited that checkpoint. And note what the app
never said: nothing about flows, decisions, subflows or steps. It reported screens and
outcomes in its own words and requests as the browser saw them, and the mapping did the
rest.
