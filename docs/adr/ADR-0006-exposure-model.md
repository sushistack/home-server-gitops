# ADR-0006: One public-default repo, kept safe by render-time tokens + a two-layer gate

Affected services: all (the rule is repo-wide)

> Decision record. Back-reference: [README → Decision records](../../README.md#decision-records-adrs).

## Context

This repo is simultaneously the deployment source of truth **and** a public
portfolio — the artifact a reviewer reads has to *be* the running system, not a
sanitized slide deck. That forces a hard question: how do ~14 services' worth of
real hostnames, IPs, the private wildcard domain, and secrets stay out of a
**public** Git repo without turning every commit into a manual redaction chore?
Manual scrubbing fails the way all manual security fails — once. The classic
answer, a public mirror of a private repo, doubles the surface area and adds a
sync step where the leak hides. See [ADR-0001](ADR-0001-why-compose-to-k3s.md)
for the public-default decision this operationalizes.

## Decision

Keep a **single public-default repo** (not a public/private mirror pair) and
make exposure a property of the **mechanism**, not of operator vigilance:

- **`internal/` and `secrets/` are git-ignored.** Real addresses, topology, and
  private diagrams live only there; a committed `internal/tokens.example.env`
  lists the token *keys* as placeholders so the shape is public but the values
  are not.
- **Render-time token substitution is the strongest control.** Every sensitive
  value appears in tracked files **only** as a `${SECRET:NAME}` enum token
  (`${SECRET:DOMAIN_PUBLIC}`, `${SECRET:IP_LAN_GATEWAY}`, …); real values are
  injected at deploy/local time (`bin/render`) into git-ignored output. Because
  no file with real values is ever tracked, "remembering to redact" stops being a
  step you can forget — **you cannot leak what you never commit.**
- **Two-layer gate.** (1) **Automatic** — `gitleaks` over the **full git
  history** (not just the working tree): one regex allowlists the token shape,
  denylist *patterns* (raw IPv4, `*.<zone>`, internal TLDs) fail anything that
  looks like a real address but isn't a token. Runs both as a pre-commit hook and
  in CI. (2) **Human** — `docs/RELEASE-CHECKLIST.md` gates what the scanner
  cannot read: demo clips, diagrams, terminal screenshots.
- **The functional split, not a security split.** The private `home.server` repo
  (Ansible/Terraform/Proxmox/Compose, full of real addresses) and this public
  repo are **two single repos with different jobs**, not two views of one. There
  is no scrub-on-push because there is nothing to scrub.

## Consequences

- The denylist is expressed as **patterns, never a literal list of the real
  house's addresses** — a literal list in a public file would itself be the leak.
  Two fixed constants (`cluster.local`, `0.0.0.0`) are explicitly allowlisted
  because they reveal no topology.
- `internal/tokens.example.env` is **scanned too** (not path-exempted): it is the
  file most likely to catch a fat-fingered real value, so it must be subject to
  the gate.
- Diagram text labels obey the same rule — the scanner reads SVG text, so a real
  host in a label fails CI; raster (PNG) is forbidden partly because it is *not*
  text-scannable (see [ADR-0005](ADR-0005-ingress-tls.md) and the diagram
  convention).
- A full-history scope means a leaked value survives until a rebase, so the gate
  catches it even after a "fix" commit — the cost is that history rewrites are
  occasionally needed, accepted as the price of a real guarantee.

## Rejected alternatives

- **Public/private mirror.** Two repos to keep in sync, and the sync step is
  exactly where a real value slips into the public side. Doubles surface for no
  benefit the token mechanism doesn't already give. Rejected.
- **Scrub-before-push (manual redaction).** Relies on never forgetting, over
  hundreds of commits, forever. Manual security fails once and is then public
  permanently. Rejected.
- **Private-only repo.** Safe, but defeats the entire portfolio goal — the repo
  exists to be read. Rejected.

## Exposure note

Safe to show publicly: the whole mechanism — token convention, render-time
substitution, the two-layer gate, full-history scope, and why patterns-not-lists.
That transparency is the point: a reviewer should be able to see exactly how the
repo stays safe. Not shown (by construction): any real value the mechanism
protects. This ADR contains no token values, no addresses, and no denylist
literals — it describes the gate without being a hole in it.
