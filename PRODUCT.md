# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

macOS first (the focus), with an iPhone app that acts as a remote for the Mac.

## Users

One person: Moizes, the developer and only user. A Brazilian, bilingual (Portuguese and English) builder who lives in WhatsApp, iMessage and Claude, and wants a copilot that knows him.

## Product Purpose

Agott is a self-hosted personal copilot, a "Muse" that sits over whatever app is open. Hold a key, speak or type, and it answers with full knowledge of your conversations, screen, calendar, tasks and mail. It can also act on the Mac (click, type, AppleScript). Success means it explains a confusing WhatsApp message with examples, suggests replies in your own voice, reads your relationships honestly, and does small chores without you leaving the app you're in.

## Positioning

It runs on your own Mac against your own message databases (WhatsApp, iMessage, Claude Code history), with a knowledge graph of your life built on-device. The model is your choice: OpenCode Go (DeepSeek), Apple Private Cloud Compute, or Apple's on-device model, all through Foundation Models.

## Operating Context

- Primary surface: the floating overlay over other apps (WhatsApp first). The main window is secondary, used for browsing People, Memory, Graph and You.
- Input: hold Right Option to talk, tap it to type; Rambler-style dictation cleanup, inspired by the user's Shirusu app.
- The iPhone pairs over the local network and talks to the Mac's Agott.

## Capabilities and Constraints

- Sources: WhatsApp desktop store, iMessage chat.db, Claude Code transcripts, claude.ai exports. Needs Full Disk Access, Accessibility and Screen Recording.
- Hybrid RAG (FTS5 + on-device embeddings + graph), relationship analytics, fact extraction batched to a share of the model context.
- Tools: memory, computer use, AppleScript, calendar, reminders, mail drafts, generative cards (explanations, replies, checklists, relationship reads).
- Approvals before any side effect unless Autopilot is on.
- Localized with an Xcode String Catalog: English and Brazilian Portuguese.

## Brand Commitments

- Name: Agott.
- Cute. Explicitly not bound to standard macOS UI ("it doesn't need to follow the macOS UI but it should be cute and working").
- Mascot: the user-supplied black-and-white manga-style character (`Agott/Assets.xcassets/Mascot.imageset`, `MascotHead.imageset`), also the app icon foreground (`Agott/Agott Icon.icon`).
- Animated "cute faces" with moods (MuseFace) are a requested feature; the mascot image itself is the face (MascotFace), with mood shown by a breathing ink ring.
- Since 2026-11-08 the look is sober and notebook-like, in the spirit of Granola: neutral greys (a sidebar a shade darker than the page), near-white type in dark mode, the system serif for page headlines and the system face everywhere else, cards a step lighter than the page with a 1 pt hairline and 16 pt corners, capsule buttons (solid for the main action, outlined otherwise), outlined filter pills, rows with an icon tile, a title, a muted description and their control. One colour, the system purple (`Ink.spot`, the tint Liquid Glass uses), marks what is selected or live. No glass as decoration, no screentone, no pink fills, no hero-number tiles.
- Navigation: a fixed sidebar (Home, Chat, People, Memory, Graph, You, then recent conversations; Settings and you at the foot); Home shows what is coming up on the calendar and conversations by day; the chat has no bubble for Agott, a grey pill for you, History and New conversation in its top bar; Settings open inside the window.
- Activity reads like Claude's: a small dotted orb (after thinking-orbs) for the kind of work, the step, the seconds, and a chevron to the steps and the thinking.
- The mascot stays the app's character (icon, onboarding), not decoration on screens.
- People named in replies are chips: avatar, name, a button under the pointer, their card above them.

## Evidence on Hand

- Real data stays private; screenshots and reviews use the `-AgottDemo` launch mode with made-up people.

## Product Principles

1. The overlay is the product; the window is the archive.
2. Show, don't tell: cards over paragraphs.
3. Never act behind the user's back; ask first by default.
4. Sound like the user when writing for the user.
5. Private by construction: local store, chosen model, only the needed passages leave the Mac.
