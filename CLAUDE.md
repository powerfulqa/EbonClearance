# Agent entry point

If you're an AI agent or a new contributor, **read [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) first**. It is the prescriptive guide for working in this codebase and covers:

- WoW 3.3.5a / WotLK / Lua 5.1 constraints (no `C_Timer`, no `goto`, no retail APIs)
- Single-file architecture, the one event hub, and state-machine conventions
- Cached API upvalue patterns for hot paths
- SavedVariables migrations via `EnsureDB`
- Interface Options panel idempotency
- The decision record for **not** embedding Ace3
- **Gotchas and refactoring traps** — non-obvious design choices that have silently broken in the past. Read this before you "simplify" anything.

## The short version

- This is a WoW 3.3.5a addon for Project Ebonhold, one file: [EbonClearance.lua](EbonClearance.lua)
- No external libraries. All Blizzard APIs.
- Run `stylua EbonClearance.lua && luacheck EbonClearance.lua` before committing. Luacheck sits at **0 warnings** (cleaned post-v2.6.0); keep it at zero. If a new warning appears, fix the cause or extend [`.luacheckrc`](.luacheckrc) — do not silence with blanket directives.
- Known deferred refactors are tracked in [docs/CODE_REVIEW.md](docs/CODE_REVIEW.md). Don't repeat items that are already there — cite them by number if you touch adjacent code.

## Conventions at a glance

- Everything is `local`, prefixed `EC_`. Globals are `EbonClearanceDB` and the slash-command handles only.
- Chat output goes through `PrintNice` / `PrintNicef`. Never call `DEFAULT_CHAT_FRAME:AddMessage` directly.
- State transitions use `STATE.*` constants (not raw strings) so typos fail loudly.
- Forward-declare `local` variables at the top of the file when functions defined earlier need to capture them as upvalues. This bit us in v2.0.12 and is now explicit.

## Release process

- Bump version by pushing a `v*` tag; the GitHub workflow rewrites the `.toc` from the tag automatically
- Manual version-bumps to the `.toc` are not needed
- Release artifacts include `EbonClearance.lua`, `EbonClearance.toc`, `Bindings.xml`, and `LICENSE`

For everything else, [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) is authoritative.
