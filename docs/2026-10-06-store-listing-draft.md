# App Store listing — DRAFT for merakizzz to edit

Status: **draft, not submitted.** Nothing here has gone to App Store Connect.
Written against zeus-ios `main` @ `1c50e3d`. Every line is a proposal; edit freely.
Character limits are Apple's (name 30, subtitle 30, keywords 100 bytes, promo 170).

Excluded on purpose: the encryption-compliance answer (merakizzz's legal call).

## Name (≤30)
Zeus — NovaXAI

## Subtitle (≤30)
Your AI agent, in your pocket            <!-- 29 chars -->

## Promotional text (≤170)
Talk to Zeus. Ask, attach, and act — by voice or text — with an AI agent that runs its core on your device and connects to your own Zeus gateway when you want it to.

## Description
Zeus is the mobile console for the NovaXAI Zeus agent.

TALK TO IT
Tap the orb and speak. Zeus listens, answers, and can read its replies back to you. Prefer typing? The keyboard is one tap away.

SHOW IT THINGS
Attach images and documents (PDF, Word, text, Markdown) to a conversation. Images go to vision-capable models; documents are read into the session.

YOUR MODELS, YOUR KEYS
Bring your own provider and API key. Zeus fetches the models your key can use, or you can type one in.

ON THE PHONE, OR ON YOUR GATEWAY
Zeus's core runs on the device itself. Point it at your own Zeus gateway to pick up your sessions and memory from there.

SESSIONS AND MEMORY
Revisit past sessions, including the tools the agent used, and search what Zeus has remembered.

VISION PRO
The same app runs on Apple Vision Pro. Features that need iPhone hardware are shown as unavailable there rather than hidden.

## Keywords (≤100 bytes, comma-separated, no spaces after commas)
AI,agent,assistant,voice,chat,LLM,Claude,OpenAI,gateway,automation,memory,vision,NovaXAI
<!-- 89 bytes. Third-party model names (Claude/OpenAI) are a trademark call — drop if unsure. -->

## Category (proposal)
Primary: Productivity · Secondary: Developer Tools

## Claims to verify before submission
- "reads its replies back" — narration exists in Settings; confirm it's on in the build being shipped.
- PDF/Word attachments — depends on the attachment-routing arc being on `main` at the archived sha.
- Gateway sessions/memory — needs a reachable gateway; reviewers won't have one. App Review notes should say how to use the on-device mode instead.

## Screenshots
- **iPhone (6.9", 1320×2868):** 5 frames from `scripts/capture_store_screens.sh` @ `1c50e3d`, verifier OK (all distinct, AX5 set distinct). Output in `build/store-screenshots-iphone-17-pro-max/` (gitignored, reproducible).
- **Vision Pro (3840×2160): NOT READY.** Simple `simctl io screenshot` frames of the full visionOS scene all came back the same screen per the verifier (d≤5, since the app window is a small part of a mostly static scene). Cropped to the window, 4 of 5 are distinct, but commissioning and summary still collide (d=6). A VP capture path is its own piece of work.
