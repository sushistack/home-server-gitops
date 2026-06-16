# Release Checklist — Human Exposure Gate (Layer 2)

The automatic scanner (Layer 1: gitleaks + pre-commit + CI over full history) covers
**text** only. It cannot read pixels, audio, or rendered video. Anything the scanner
**cannot machine-read** is gated here. Run this before publishing ANY such artifact
(demo clip, screenshot, diagram, GIF, recorded terminal).

## Before publishing any visual/recorded artifact

- [ ] **Terminal prompts** show no real hostname or username (`user@real-host`). Use a generic prompt or a logical/token name.
- [ ] **Browser address bar** shows no real domain — no private wildcard domain, no internal domain, no raw IP. Use the public/logical name only.
- [ ] **Command output** (e.g. `kubectl get nodes`, `ip a`, `cat /etc/hosts`) shows no real node name, internal hostname, or RFC1918 / public IP.
- [ ] **Diagram labels** (Excalidraw / draw.io / raster exports) use logical or `${SECRET:*}` token names — never a real host, IP, or domain.
- [ ] **Window titles, tabs, bookmarks, notifications** captured in the frame leak no real host/domain.
- [ ] **EXIF / metadata** on exported images carries no location or device hostname.
- [ ] **Audio narration** (if any) speaks no real hostname, IP, or domain aloud.

## Rule

If in doubt, **re-record with logical names** rather than blur-after-the-fact. A blurred
frame that's still legible in one keyframe is a leak. Layer 1 keeps tracked text safe by
mechanism; this list is the only thing standing in front of the artifacts it can't see.
