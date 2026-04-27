# Notice — prior art and convergent patterns

This file documents the design lineage of EbonClearance honestly, so
that any future "they copied us" or "you copied them" claim has a
record to refer to. Convergence on similar shapes is acknowledged
where it exists; originality is not claimed where the pattern is
shared with the broader WoW 3.3.5a addon ecosystem.

---

## Convergent patterns in the 3.3.5a niche

EbonClearance ships in a niche that several other addons also
target: automated inventory management for a single private server,
sharing a small set of WoW 3.3.5a APIs and a single core gameplay
loop (loot, summon, sell, repair, repeat). Heavy feature parity
between addons in this niche - auto-loot cycles, companion-pet
management, mount-aware behaviour, stuck-detection heuristics,
batched selling with disconnect-prevention caps, two-scope item
lists, hand-rolled minimap buttons, three-keybind `Bindings.xml`
files, and so on - reflects that small API surface and that single
loop converging on broadly similar solutions. Convergence on the
same shape is not, in itself, evidence of copying in either
direction.

---

## Source-available licence pattern

EbonClearance ships under a custom **source-available attribution
licence**. The structural shape (Grant / Attribution / No-Rebrand /
Forks / Non-commercial / No-Warranty / Termination / Severability)
follows similar source-available licences that have appeared in the
3.3.5a private-server addon ecosystem before this one. EbonClearance
does not claim its licence structure is original; the structure was
adopted because it is the right shape for the same anti-rebrand
pressure other addons in this scene are reacting to.

---

## Provenance globals pattern

EbonClearance writes the following globals at addon load:

```
EBONCLEARANCE_IDENT       = "EbonClearance"
EBONCLEARANCE_AUTHOR      = "Serv"
EBONCLEARANCE_ORIGIN      = "<canonical github url>"
__EbonClearance_origin    = "<canonical github url>"
__EbonClearance_author    = "Serv"
__EbonClearance_watermark = "<derived hex hash>"
```

The `__<addon>_origin` / `__<addon>_author` form (double-underscore
prefix, addon name, role suffix) is a pattern that has appeared in
other 3.3.5a addons before this one. EbonClearance does not claim
the pattern is original; it is deliberately compatible with
something the broader scene is settling on for the same anti-rebrand
reasons.

The `__EbonClearance_watermark` global and the export-string
fingerprint suffix (`;fp=<6 hex>`) are EbonClearance-specific. See
[`docs/ADDON_GUIDE.md`](docs/ADDON_GUIDE.md) "Fingerprint and
watermark" section for the convention and how to verify the value.

---

## Verifiable timeline

EbonClearance has been on GitHub publicly since 2026-04-05 with full
commit history visible at
https://github.com/powerfulqa/EbonClearance. Anyone wishing to check
which features shipped publicly when can clone the repository and
review the commit log.

---

## The honest summary

- **Core gameplay loop**: developed independently with full public
  commit history.
- **Licence structure and provenance globals**: adopted patterns
  that exist elsewhere in the 3.3.5a addon ecosystem with
  acknowledgement (this file), not original to this project.
- **Fingerprint and watermark mechanism**: specific to this project.

If you are reading this file in a derivative addon's source tree,
that addon is required by EbonClearance's
[LICENSE](LICENSE) to preserve this file in full and link to
https://github.com/powerfulqa/EbonClearance.
