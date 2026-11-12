# Computer use: accessibility first

Agott's computer-use tools (`look_at_screen`, `press`, `type_text`, `press_keys`, `scroll`, `click_at`, `open`)
read and drive other Mac apps through the Accessibility API. A screenshot is only taken when that is not enough.

## How it works

- **Reading** (`Agott/Senses/AXReader.swift`): the focused window of the app in front (or the dialog over it, which
  is all that can be used while it is up), any open menu, and the menu bar's titles. One IPC round trip per element
  for all its attributes (`AXUIElementCopyMultipleAttributeValues`), only the visible rows of tables and outlines
  (`AXVisibleRows`), nothing scrolled out of view (a scroll area clips what is inside it), a 0.5 s messaging
  timeout set on every element (never on the system-wide element), and caps of 3000 elements, depth 40, 300
  children per element and 2 s per read.
- **Compaction** (`Agott/Senses/AXTree.swift`, pure and unit-tested): keeps what can be pressed or read, drops the
  scaffolding (groups, scroll bars, splitters, unlabelled images), folds each table row into one line, drops a
  button's own caption and the window title repeated as text, shows values only where they matter (a field's text,
  a checkbox's on/off, a popup's choice), and caps the result at 7000 characters (plain text goes first, controls
  last, the focused element never). One line per element: `[12] button "Save" disabled`, `[13] field "Name"
  ="Moizes" focused`, `[14] row "Report.pdf · Today · 2 MB" selected`.
- **Addressing**: ids are handed out by an element's role, words and section, so the same control keeps its id
  from one read to the next. Acting re-reads only if the app has redrawn the element since.
- **Acting** (`Agott/Senses/ComputerControl.swift`): `AXPress` for buttons, `AXFocused` for fields, `AXSelected` for
  rows that have no press, `AXShowMenu`, `AXIncrement`/`AXDecrement`, `AXScrollToVisible`; a real click on the
  element's centre (scrolled into view first) only when the app does not support the action. Typing is by paste,
  into the element given (its text selected through `AXSelectedTextRange` to replace it).
- **Settling and what changed**: after every action Agott polls a cheap signature of the app (front app, window
  title and child count, focused element and its value) every 60 ms until two readings agree (1.5 s at most), reads
  again and returns only the difference (`+` new, `-` gone, `~` changed), or the whole window when the window or
  app changed. The model rarely needs to look again.
- **Pixels**: a screenshot of the window, read with OCR (every line with its `@x,y` for `click_at`) and, for a model
  that sees, sent as an image in the tool result, only when there is no window, almost nothing is readable, most of
  the window is one drawn view (a canvas, game, video or image), a web area exposes nothing, or the model asks
  (`look_at_screen` with `screenshot`).

The approval prompt (`Approvals.ask`) still comes before every action that changes something.

## Safari pages, from the DOM

Web pages are often thin through Accessibility, so Agott ships a Safari Web Extension (`AgottSafari`, embedded
in the Mac app's `PlugIns`). When the app in front is Safari and the extension is on (Safari ▸ Settings ▸
Extensions, allowed on the sites you want), `look_at_screen` reads the page from the page itself and the window
around it (tabs, address bar) still from Accessibility; Agott's Settings ▸ Preferences shows whether it is on and
opens Safari's settings.

- **Reading** (`AgottSafari/content.js`): the active tab's content script walks the DOM (open shadow roots too,
  only the dialog when a modal one is up), keeps what is visible and in the viewport, and names elements the way
  the accessibility tree does (`aria-labelledby`, `aria-label`, `<label>`, alt text, own text). Roles come from
  ARIA or the tag: link, button, field, search, password, textarea, checkbox, radio, switch, select, combobox,
  slider, tab, menuitem, option, heading, image, text. Table cells of a row read as one line. Landmarks (nav,
  aside, dialog, named forms and regions) become section lines. Every element gets a ref that stays the same for
  as long as the page lives.
- **Compaction** (`AgottSafari/page-core.js`, no DOM, unit-tested in JavaScriptCore): the same rules and the same
  7000-character cap as `AXCompactor` — a label's text said once, empty sections dropped, plain text cut first,
  the focused field never.
- **One list**: `SafariPage.items(ids:)` puts the page's elements under a `— Web page "Title" · URL` line in the
  window's own numbered list. Their ids come from the same id table (keyed by role, words and section), so they
  never clash with the window's controls, stay the same between reads, and `AXDiff` reports what changed after
  an action exactly as for apps. The Accessibility read skips the inside of the web area then
  (`Limits.skipWebContent`), and no screenshot is taken for it.
- **Acting** by id, through the content script, without moving the mouse or bringing Safari forward: `press`
  sends the whole pointer/mouse sequence and `click()`; `focus`, `show` (scroll into view), `menu`
  (`contextmenu`), `open` (`dblclick`), `increment`/`decrement` (`stepUp`/`stepDown`); `type_text` sets the value
  through the prototype's setter (so React and friends see it) with `beforeinput`/`input`/`change`, uses
  `insertText` for contenteditable, picks the option with that text in a select, and `submit` calls
  `requestSubmit()` on the form (or sends Enter). `scroll` scrolls the element's scrollable ancestor or the page.
  Each action waits for the page to stop changing (150 ms without mutations, 1.5 s at most), then Agott reads
  again and returns the difference.
- **Plumbing**, as Apple documents it ("Messaging between the app and JavaScript in a Safari web extension"): the
  background script keeps a native port open (`browser.runtime.connectNative`); Agott sends each request with
  `SFSafariApplication.dispatchMessage`; the background script asks the active tab's content script (putting it in
  first if the tab was open before the extension was turned on) and answers with `browser.runtime.sendNativeMessage`;
  the extension's handler (`SafariWebExtensionHandler`, sandboxed) writes the answer into the App Group container
  it shares with Agott (`<team>.br.com.zesmoi.Agott`), where `SafariBridge` is waiting for it. A ping decides
  whether the extension answers (remembered for 30 s, 8 s after a miss); when it does not, or the page cannot be
  read (Safari's own pages, a site the extension is not allowed on), everything falls back to Accessibility.
- Only the main frame is read; cross-origin iframes are not. Passwords show as `••••`.

`LiveSafariTests` (run with `TEST_RUNNER_AGOTT_SAFARI=1`, the extension on and allowed on `127.0.0.1`) opens a
local test page in Safari, lists it and presses, types, picks an option and submits through `ComputerControl`.

## What came from fazm

fazm (github.com/mediar-ai/fazm, MIT per its README) drives native apps through its bundled
`mcp-server-macos-use` (Business Source License 1.1, so none of its code was copied) on top of MacosUseSDK (MIT).
The ideas taken, reimplemented here in Agott's own code:

- read the AX tree instead of looking at pixels; keep interactive roles and anything with text, drop structural
  containers without text and scroll-bar parts;
- breadth-first caps on elements, depth, children per element (ranged `AXUIElementCopyAttributeValues`) and time;
- scope the view to a sheet when a dialog is up;
- after an action, return the diff between the tree before and after instead of the whole tree, and follow the
  app that came to the front;
- `AXSelected` for rows that have no `AXPress`, and `AXPress` when synthetic clicks are dropped;
- search the elements by text (fazm writes the tree to a file for grep; here `look_at_screen` takes `find`);
- screenshots only on demand.

Different from fazm: Agott acts by element id, not by coordinates; ids are stable across reads; table rows fold into
one line; only visible rows are read; attributes come in one batched call; the UI settle is detected instead of a
fixed 100–200 ms wait; and the screenshot fallback is decided automatically.

## Before and after

Measured by `LiveAccessibilityTests.measureBeforeAndAfter()` (run with `TEST_RUNNER_AGOTT_MEASURE=1`) on
Finder-, System Settings- and Notes-like windows built by the test itself (never the person's own apps or data),
and on Calculator, a real app in its own process. "Before" is the previous reader: every element attribute by
attribute, plus OCR of the window, which `look_at_screen` ran on every call. Tokens are about characters ÷ 4.

| Window | Before: characters | Before: ms (AX + OCR) | After: characters | After: ms |
|---|---|---|---|---|
| Finder-like (300 files, 12 places) | 7770 | 476 | 1991 | 29 |
| Settings-like (25 panes, 8 options) | 2752 | 244 | 1283 | 21 |
| Notes-like (60 notes, a long note) | 11896 | 333 | 2664 | 17 |
| Calculator (real app, AX only on both sides) | 824 | 38 | 534 | 12 |

Per step (act, then see the result): before, the action returned one line and the model looked again, paying the
whole "before" column again; now the action returns what changed, about 60 characters when one thing changed (for
example `+ [48] "Saved just now"`), plus the time to settle (≈180 ms when nothing moves).

The fixture timings are in-process, so they undercount the IPC cost both readers pay with a real app; the
Calculator row shows that cost (one batched call per element instead of five to seven). The real "before" also
included a ScreenCaptureKit screenshot, not counted here.
