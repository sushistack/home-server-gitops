# home-server-gitops

Public-default GitOps repository for a home server, built in the open.

**Public-safe by mechanism, not by scrubbing.** Tracked files reference every sensitive
value ONLY as a `${SECRET:NAME}` token. Real values live in the git-ignored
`internal/tokens.env` and are injected at render time into git-ignored output — so no
tracked file ever holds a real hostname, IP, domain, or secret.

## Exposure gate

- **Layer 1 — automatic.** `gitleaks` (`.gitleaks.toml`) allowlists the `${SECRET:NAME}`
  token shape and denies raw IPs / private domains / internal hostnames / secrets. Wired
  as a pre-commit hook (working tree) and a CI workflow over the **full git history**.
- **Layer 2 — human.** [`docs/RELEASE-CHECKLIST.md`](docs/RELEASE-CHECKLIST.md) gates the
  artifacts the scanner can't read (demo clips, diagrams, screenshots).

## Local setup

```sh
pip install pre-commit && pre-commit install        # enable the commit-time gate
cp internal/tokens.example.env internal/tokens.env  # then fill REAL values (git-ignored)
bin/render <file>                                   # -> rendered/<file> (git-ignored)
```

> Layout (`bootstrap/ argocd/ infra/ workloads/`) is stubbed here and filled in later stories.
