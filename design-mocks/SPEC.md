# PopDraft Redesign — Shared Mockup Spec

You are building ONE self-contained HTML mockup that demonstrates a redesigned macOS
menu-bar app called **PopDraft**. Six designers each build the SAME content surfaces in a
DIFFERENT visual style. This file is the shared contract so all six are directly comparable.
Your individual style brief (palette, type, shape, mood) comes separately — follow it precisely.

## Product context (what the app does)

PopDraft lives in the macOS menu bar. The user selects text anywhere, presses a hotkey, and a
small panel appears near the cursor offering quick LLM actions (Grammar, Articulate, etc.).
We are redesigning it to add:

1. A **persistent corner "bubble"** — instead of vanishing, the panel minimizes into an
   appealing bubble pinned to a screen corner (user-chosen corner). Pressing the hotkey
   transitions the bubble back into the panel at the cursor.
2. A new **default action: "Ask Agent"** — opens a full chat with a local/cloud LLM agent that
   can think, search the web, and take actions (tool use). Picking ANY non-Copy action also
   transitions into this chat experience. There is always a plain **Copy** button; pressing
   Copy returns the bubble to its corner and saves the session.
3. **Claude-style agent chat** — clean conversation, streaming, expandable "thinking", visible
   tool-call affordances (e.g. a `web_search` call with its result), and a **copy button on
   each message / code block**.
4. **User-managed models** — no fixed model list. The user pastes a model name and the UI
   instantly validates it (valid + downloadable, or valid cloud model for a pasted key).

## REQUIRED: render these four surfaces on ONE page

Lay them out as labeled "window" cards on a subtle macOS desktop canvas (faux wallpaper +
a thin top menu bar with a small PopDraft glyph at the right). Canvas width 1280px, let height
grow. Each surface is its own rounded window/card with a small caption label beneath it.
Arrange as a tidy board (e.g. 2 columns) — all four visible without scrolling horizontally.

**Surface A — Minimized bubble (resting state).**
Show a desktop corner (bottom-right) with the bubble at rest: an appealing, polished bubble
roughly 56–72px, with the PopDraft mark. Include a tiny hover/peek treatment hint (e.g. a
soft label "⌥Space to ask" or a subtle status dot showing the local model is ready). Make
this feel like something a user would happily leave on screen.

**Surface B — Action menu (text selected → hotkey pressed).**
A floating panel ~360px wide. Top: a one-line quote of the SELECTED TEXT (truncated). Then a
vertical list of actions, each a row with an icon + name + (optional) shortcut hint:
  - **Ask Agent**  ⌥Space   ← the NEW DEFAULT, visually primary / highlighted / first
  - Grammar Check  ⌃⌥G
  - Articulate  ⌃⌥A
  - Craft a Reply  ⌃⌥C
  - Explain Simply
  - Continue Writing
  - Read Aloud  ⌃⌥S
A persistent **Copy** affordance at the bottom (or as a footer button). Show one row in a
hover/selected state.

**Surface C — Agent chat (Claude-style).** This is the centerpiece — make it shine.
  - Header: session title + a "minimize to bubble" control + model indicator
    (e.g. "Qwen2.5-7B · local" with a small green ready dot).
  - The pasted SELECTED TEXT appears as a context quote/chip at the top of the conversation.
  - A user message: "Make this more concise, and double-check the 40% pricing claim."
  - An assistant turn that shows, in order: a collapsible **Thinking** line ("Reasoning…"),
    a **tool call** affordance — `web_search("enterprise SaaS pricing benchmark 2026")` — with
    a compact result snippet, then the streamed answer (a concise rewrite). Show a blinking
    cursor or "streaming" hint on the last line to convey live streaming.
  - **Per-message copy button** (and a copy button on any code/quote block). Make the copy
    affordance clearly visible — it's a core requirement.
  - Bottom: a chat input with a placeholder ("Ask anything, or paste more text…") and a
    send button; small tool chips (Web, Actions) near the input.

**Surface D — Model settings (paste-to-validate).**
A settings card with:
  - A text field where the user has typed a model name, e.g. `Qwen2.5-7B-Instruct-GGUF`.
  - A live **validation chip** in the VALID state: e.g. "✓ Found on Hugging Face · Q4_K_M ·
    4.7 GB" with a **Download** button. Include a subtle second example showing an INVALID
    state chip ("✕ Not found") so the instant-feedback idea is obvious.
  - A small row for cloud providers: a provider segmented control
    (Local / OpenAI / Anthropic / Gemini / OpenRouter), an API-key field (masked), and a
    "✓ key valid" chip.

## Realistic content (NO lorem ipsum)
Use believable copy throughout. Suggested SELECTED TEXT to reuse across B and C:
> "Our platform helps teams ship faster. We've seen customers reduce their deployment time by
> 40% on average, and onboarding usually takes just a couple of days."

The agent's rewrite (assistant message) should be a genuinely tighter version, and reference
that it verified the 40% figure via the web_search result.

## Technical constraints
- **One file**, self-contained: inline `<style>` (and inline `<script>` only if needed for a
  tiny hover demo — static is fine). No build step, no external JS libraries.
- Prefer **Apple system fonts** for authenticity: `-apple-system, "SF Pro Text", "SF Pro
  Display", system-ui` for UI; `ui-serif, "New York", Georgia` for serif; `ui-monospace, "SF
  Mono", "JetBrains Mono", monospace` for code/tool calls. You MAY add ONE Google Font via
  `<link>` if your style brief calls for a distinctive display face — but always include
  system fallbacks so it renders even offline.
- Use real SVG icons (inline) or SF-Symbol-like simple glyphs; avoid emoji-as-icons unless the
  style brief embraces it.
- Polished details matter: spacing rhythm, shadows/elevation, focus states, a hover state
  somewhere, rounded radii consistent with the brief. This is a portfolio-quality mock.
- Must render correctly at 1280px wide in a headless Chromium screenshot. Avoid anything that
  depends on user interaction to look complete (static states should already look finished).

## Output
Write your file to the EXACT path given in your individual brief
(e.g. `/Users/ofer/dev/llm-mac/design-mocks/mock-1-liquid-glass.html`). Then STOP and return a
2–3 sentence description of the distinctive choices you made. Do not screenshot — that's a
later step.
