---
name: corbado-observe
description: Integrate Corbado Observe into a frontend application to measure
  authentication flows (login, signup, recovery, enrollment) with events like
  flow_started, flow_finished, decisions, and subflow steps. Use when adding
  Corbado Observe, authentication analytics, or passkey/login funnel tracking
  to a web app.
---

# Corbado Observe integration

Corbado Observe is fire-and-forget telemetry for authentication journeys. You instrument the
customer's frontend with structured events; Corbado turns them into funnels, flows, and
drop-off analytics. Instrumentation must NEVER change or break existing app behavior — add
tracking calls at semantically correct points with minimal diffs.

## Setup

Install the SDK. `projectId` and `apiBaseUrl` come from the Corbado management console
(https://app.corbado.com → Observe → Settings). Keep `debug: true` in development/staging,
`false` in production.

```bash
npm install @corbado/observe
```

Recommended setup: wrap `init()`/`getTracker()` in ONE small module that lazily
initializes on first use and returns `null` when configuration is missing. Every call
site then guards with `?.` — so tracking can never throw or break the app, and it is
automatically disabled in environments without Observe config.

```typescript
// corbadoObserveTracker.ts — the only file that touches init()
import { getTracker, init, type CorbadoTracker } from "@corbado/observe";

let isInitialized = false;

export const getCorbadoObserveTracker = (): CorbadoTracker | null => {
  // Adapt to the app's config system (env vars, global config object, ...)
  const projectId = process.env.CORBADO_OBSERVE_PROJECT_ID;
  const apiBaseUrl = process.env.CORBADO_OBSERVE_API_BASE_URL;
  if (!projectId || !apiBaseUrl) return null;

  if (!isInitialized) {
    init({ projectId, apiBaseUrl, debug: false });
    isInitialized = true;
  }

  return getTracker() ?? null;
};
```

All tracking calls go through this accessor with optional chaining:

```typescript
getCorbadoObserveTracker()?.flowStarted({ flowName: "login", touchpoint: "account" });
```

Optional `init` options: `defaultTags` (key-value strings added to every event),
`applicationId` (channel like `"web"`/`"ios"` when one project tracks multiple channels).
For plain HTML sites without npm, a CDN snippet exists — see
https://docs.corbado.com/corbado-observe/overview/getting-started (with the CDN, call
`Corbado.get().flowStarted(...)` per event; never store the instance).

## Data model — what to instrument

- **Flows** — end-to-end journeys: `login`, `signup`, `recovery`, `enrollment`.
  NOT auto-discovered; you must send flow events.
- **Decisions** — explicit branch points (e.g. choosing between passkey and password).
  NOT auto-discovered; you must send decision events.
- **Subflows** — one concrete auth method attempt (passkey login, password login,
  email OTP, ...). Auto-discovered from the step events you send via SDK helpers.
- **User references** — link events to the app's own users (`userId`, `identifier`).

## Integration playbook

1. Map every auth entry point (login page, signup page, combined auth form, checkout
   login, post-login passkey prompt) to a flow type and a stable `touchpoint` string.
2. Fire flow lifecycle events at those points.
3. Fire decision events wherever the user or system picks between auth methods.
4. Wrap each concrete auth method with its subflow operation helper.
5. Pass user references as soon as identity is known — at minimum on `flow_finished`
   (`flowFinished()`).
6. Verify with `debug: true` (events log to the browser console) — check event names,
   payloads, and ordering by walking through each journey.

## 1. Event catalog

Every SDK method emits exactly one event (1:1 mapping). The wire event name is what
appears in debug logs, network payloads, and the Corbado backend.

| Event | SDK method | When to send | Key payload fields |
| --- | --- | --- | --- |
| `flow_started` | `flowStarted()` | User enters an auth touchpoint | `flowName` or `flowNames` (+ `defaultFlowName`), `touchpoint` |
| `flow_decided` | `flowDecided()` | Ambiguous entry resolves to one flow | `flowName` |
| `flow_finished` | `flowFinished()` | Flow completes successfully | `flowName`, `userId`, `identifier` |
| `flow_reset` | `flowReset()` | In-progress flow is restarted | `flowName` or `flowNames` |
| `flow_auto_finished` | `flowAutoFinished()` | Flow completed implicitly by another flow | `flowName`, `finishedByFlowName`, `userId` |
| `conversion` | `conversion()` | Business conversion outside auth (purchase, add-to-cart) | `name`, `touchpoint`, `userId` |
| `auth_method_decision_started` | `authMethodsDecisionStarted()` | Auth method choices are shown or change | `decisionName`, `options` (`AuthMethodType[]`), `explicitDecisionValue` |
| `auth_method_decision_finished` | `authMethodsDecisionFinished()` | Outcome known AND no subflow follows (skip/dismiss) — see section 3 | `decisionName`, `options`, `explicitDecisionValue` |
| `auth_decision_started` | `authDecisionStarted()` | A non-method decision point becomes visible | `decisionName`, `options` (`string[]`) |
| `auth_decision_finished` | `authDecisionFinished()` | A non-method decision outcome is known | `decisionName`, `options`, `explicitDecisionValue` |
| `subflow_started` | `op.subflowStart()` (auto for input-bound helpers) | Subflow UI is shown / offered | `explicitSpecType` (`subflowType` stamped by the helper) |
| `subflow_trigger` | `op.trigger()` | Subflow is interacted with | `actor` (`"user"`/`"system"`), `explicitSpecType` |
| `subflow_step_started` | `op.<step>.start()` | A step of the subflow begins | step data, `explicitSpecType` on the first step |
| `subflow_step_finished` | `op.<step>.finished()` | The step completed successfully | step data (e.g. `assertionResponse`) |
| `subflow_step_error` | `op.<step>.error()` / `.errorTyped()` | The step failed | normalized error / typed `code` |

The `op.*` methods live on the subflow operation helpers (section 4), which stamp
`subflowType` and `stepName` automatically. For a subflow without a helper (e.g. TOTP),
use the low-level tracker equivalents with the same 1:1 mapping:
`trackSubflowStarted(subflowType, data)`, `trackSubflowTrigger(...)`,
`trackSubflowStepStarted(subflowType, stepName, data)`, `trackSubflowStepFinished(...)`,
`trackSubflowStepError(...)`.

(`subflow_finished` / `subflow_error` also exist but are not sent in normal
integrations — subflow outcome is derived from step events.)

## 2. Flow events

Use `flowName` when the path is known (dedicated `/login` route). Use
`flowNames: ["login", "signup"]` (+ optional `defaultFlowName`) for a combined form where
the outcome is unknown at entry, then send `flow_decided` (`flowDecided()`) once resolved.

```typescript
// dedicated /login route
getCorbadoObserveTracker()?.flowStarted({ flowName: "login", touchpoint: "account_login" });
// ... authentication succeeds
getCorbadoObserveTracker()?.flowFinished({ flowName: "login", userId: "usr_123", identifier: "max@example.com" });

// combined auth form
getCorbadoObserveTracker()?.flowStarted({ flowNames: ["login", "signup"], defaultFlowName: "login", touchpoint: "account" });
getCorbadoObserveTracker()?.flowDecided({ flowName: "signup" }); // after user-exists check
```

Every started flow should eventually get a `flow_finished` (`flowFinished()`) or
`flow_reset` (`flowReset()`). Most flow methods accept optional tags as a second
argument: `flowStarted({...}, { country: "de" })`.

## 3. Decision events

Use `auth_method_decision_started` / `auth_method_decision_finished`
(`authMethodsDecisionStarted()` / `authMethodsDecisionFinished()`) when choosing an
**authentication method** (options use predefined `AuthMethodType` values such as
`passkey-login-known-identifier`, `passkey-login-cui`, `passkey-enrollment`,
`password-login-known-identifier`, `password-login-with-identifier`, `email-otp-login`,
`email-link-login`, `social-google`, `social-apple`, `reset-flow`; custom strings are also
allowed). Use `auth_decision_started` / `auth_decision_finished`
(`authDecisionStarted()` / `authDecisionFinished()`) for everything else
(e.g. accept/dismiss prompts).

**Lifecycle rule — started always, finished only when nothing follows:**

- ALWAYS send `started` when the decision point is shown (and again whenever the offered
  options change, e.g. the user clicks "show other methods").
- If the user's choice leads into a **subflow** (they pick passkey, password, OTP, ...),
  do NOT send `finished` — the following subflow events resolve the decision
  automatically on the backend.
- If **no subflow follows** (skip, dismiss, cancel, "not now"), you MUST send `finished`
  by hand with the chosen `explicitDecisionValue` — otherwise the decision stays
  unresolved.

Keep `decisionName` short and stable.

Example — post-login passkey enrollment prompt with a "Create passkey" and a "Skip"
button:

```typescript
// Prompt is shown → always send decision started
getCorbadoObserveTracker()?.authMethodsDecisionStarted({
  decisionName: "enrollment-user",
  options: ["passkey-enrollment", "skip"],
});

// Case A: user clicks "Create passkey" → passkey-enrollment subflow follows.
// Send NO decision finished; just run the subflow (trigger + steps, section 4).

// Case B: user clicks "Skip" → no subflow follows, finish the decision by hand:
getCorbadoObserveTracker()?.authMethodsDecisionFinished({
  decisionName: "enrollment-user",
  options: ["passkey-enrollment", "skip"],
  explicitDecisionValue: "skip",
});
getCorbadoObserveTracker()?.flowFinished({ flowName: "enrollment", explicitOutcome: "skipped" });
```

## 4. Subflows (auth method attempts)

Get an operation helper from the tracker, then call `.start(data)`, `.finished(data)` or
`.error(err)` on each step around the corresponding app logic. Pass `explicitSpecType` on
the first step's `start()`. A step failure = `.error(e)` instead of `.finished()`.

Two lifecycle events frame a subflow — do not confuse them:

- **`subflow_started`** (`op.subflowStart({ explicitSpecType })`) — the subflow **is
  shown** / becomes available to the user, e.g. a password field or OTP input is
  rendered. For the input-bound helpers (`provideIdentifierOperationFull`, password
  helpers with `autoTrackConfig`) the SDK sends this automatically when the helper is
  constructed with the input element; for other subflows send it manually when the
  method's UI becomes visible.
- **`subflow_trigger`** (`op.trigger({ actor: "user" | "system" })`) — the subflow **is
  interacted with**: the user clicks "Sign in with passkey" (`actor: "user"`) or the
  system auto-starts the method (`actor: "system"`). For input-bound helpers the
  interaction (typing, CUI autofill) is auto-detected — do not send the trigger manually.

Observe uses the gap between shown and interacted for engagement metrics, and a subflow
without a trigger means "offered but never touched". Steps may legitimately run before
the trigger (e.g. a background `get-options` while the button is still idle).

| Helper (on tracker) | Subflow | Steps | Spec types (`explicitSpecType`) |
| --- | --- | --- | --- |
| `provideIdentifierOperationFull(inputEl)` | provide-identifier + passkey CUI | `provideIdentifier.postResponse`; `cui.getOptions` / `cui.ceremony` / `cui.postResponse` | `email`; `passkey-cui` (triggers auto-detected from the input field) |
| `passkeyLoginFullOperation()` | passkey-login | `getOptions`, `ceremony`, `postResponse` | `passkey-known-identifier`, `passkey-no-identifier`, `passkey-cui` |
| `passkeyEnrollmentFullOperation()` | passkey-enrollment | `getOptions`, `ceremony`, `postResponse` | `conditional-auto-manual`, `auto-manual`, `manual` |
| `passwordLoginFullOperation(autoTrackConfig?)` | password-login | `postResponse` | `password-known-identifier`, `password-with-identifier` (trigger auto-detected from the password input) |
| `passwordEnrollmentFullOperation(autoTrackConfig?)` | password-enrollment | `postResponse` | `password-set`, `password-reset` |
| `emailOtpOperationFull()` | email-otp | `send`, `postResponse`, `resend` | `email-otp-login`, `email-otp-enrollment` |
| `emailLinkOperationFull()` | email-link | `send`, `postResponse`, `resend` | `email-link-login`, `email-link-enrollment` |
| `socialLoginOperationFull()` | social-login | `getRedirectUrl`, `exchangeCode` | `pre-identifier`, `post-identifier` |

Example — passkey login behind a "Sign in with passkey" button (identifier known):

```typescript
const op = getCorbadoObserveTracker()?.passkeyLoginFullOperation() ?? null;
op?.trigger({ actor: "user" }); // user clicked the button; "system" if auto-started

let options, response;

try {
  op?.getOptions.start({ explicitSpecType: "passkey-known-identifier" });
  options = await fetchAssertionOptions(email);
  op?.getOptions.finished({ assertionOptions: JSON.stringify(options) });
} catch (e) {
  op?.getOptions.error(e);
  return;
}

try {
  op?.ceremony.start({});
  response = await startWebAuthnAuthentication(options);
  op?.ceremony.finished({ assertionResponse: JSON.stringify(response) });
} catch (e) {
  op?.ceremony.error(e); // also fires when the user cancels the passkey prompt
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

Call `.error()` on the step that actually failed, then stop tracking further steps of this
attempt (a retry is a new sequence of step events).

Input-bound helpers (`provideIdentifierOperationFull`, password helpers with
`autoTrackConfig`) attach listeners to the input element: construct them when the input
mounts, keep the instance in a ref, and call `op.destroy()` on unmount. In React:

```typescript
const passwordOpRef = useRef<PasswordLoginOperationFull | null>(null);

useEffect(() => {
  if (passwordInputRef.current) {
    passwordOpRef.current = getCorbadoObserveTracker()?.passwordLoginFullOperation({
      inputHtmlField: passwordInputRef.current,
      explicitSpecType: "password-known-identifier",
    }) ?? null;
  }
  return () => {
    passwordOpRef.current?.destroy();
    passwordOpRef.current = null;
  };
}, []);

// on submit: passwordOpRef.current?.postResponse.start({}) ... .finished({}) / .error(e)
```

Custom steps beyond the predefined ones: `op.customStep("my-step").start({})`.

Password subflows support typed error codes — prefer them over raw errors when the cause
is known: `op.postResponse.errorTyped({ code: "invalid_password" })` (login codes:
`invalid_password`, `user_not_found`, `account_locked`; enrollment:
`requirements_not_fulfilled`).

## 5. User references and tags

- Pass `userId` (stable internal ID; a hash is fine) and `identifier` (e.g. email) as soon
  as identity is known: in `flowFinished()` data, or per step via the options argument
  `{ userReference: { userId, identifier } }`.
- Tags are optional `Record<string, string>` for segmentation (country, experiment
  variant) — set globally via `defaultTags` or per event as the extra argument. Never use
  tags for identity; never use raw user IDs as tag values.

## 6. Verify the integration

1. Run the app with `debug: true` and walk through every instrumented journey (success
   AND failure/cancel paths).
2. In the browser console, confirm each expected event fires exactly once, in order, with
   correct `flowName`/`touchpoint`/`explicitSpecType` and a user reference on completion.
3. In the network tab, confirm event batches POST to the configured `apiBaseUrl`.
4. Check the dashboards at https://app.corbado.com to see flows and subflows appear.

Common mistakes: forgetting `flow_finished` (`flowFinished()`) on success paths that
redirect immediately; firing `flow_started` (`flowStarted()`) on every re-render instead
of once per journey entry; sending `subflow_step_finished` (`.finished()`) for a step
that failed instead of `subflow_step_error` (`.error()`); omitting `explicitSpecType` on
the first step; sending `auth_method_decision_finished` when a subflow follows the
choice (it resolves the decision automatically) or forgetting it when none does
(skip/dismiss).
