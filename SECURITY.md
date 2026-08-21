# Security Policy

## Reporting a vulnerability

Report suspected security vulnerabilities in Bit **privately** - do not open a
public issue, discussion, or pull request.

Preferred: GitHub's private vulnerability reporting on this repository.

1. Go to the **Security** tab.
2. Click **Report a vulnerability**.
3. Fill in the advisory form (affected component, reproduction, impact).

This opens a private draft security advisory visible only to you and the Bit
maintainers, with its own discussion thread.

**Fallback, while private vulnerability reporting is being enabled on this
repository:** email **security@byteink.io**. This is a real, monitored
maintainer channel - use it if the "Report a vulnerability" button isn't
present under the Security tab yet. Once GitHub PVR is confirmed live here
(`gh api repos/byteink/bit/private-vulnerability-reporting`), it becomes the
sole channel and this fallback is removed.

No PGP key is published for this address yet - treat it as best-effort,
unencrypted transport. If your report needs confidentiality in transit
stronger than plain email/TLS gives you, hold the full exploit details:
send only enough to confirm a channel and severity class, and we'll agree
on how to exchange the rest.

Do not include exploit code usable against third parties in the initial
report; maintainers will ask for detail as needed once the report is
triaged.

## Response SLA

- **Acknowledgment**: within **72 hours** of submission.
- **Triage / severity assignment**: within **7 days** of submission, using
  CVSS to set severity and an initial fix timeline.

These are maximums, not targets - most reports are acknowledged faster.

## Coordinated disclosure / embargo

Once a report is confirmed, we hold it under embargo while a fix is
developed:

- Default embargo: **90 days** from confirmation, or sooner if a fix and
  advisory are ready and the reporter agrees.
- The embargo can be shortened or extended by mutual agreement with the
  reporter (e.g. active exploitation shortens it; a complex fix may need
  more time, communicated before the default window expires).
- The fix and the public GitHub Security Advisory ship together at the end
  of the embargo.

## CVE issuance

Bit's GitHub repository is registered (or will be registered, ahead of the
first advisory) as a **GitHub CNA**-scoped repository. CVE identifiers for
confirmed vulnerabilities are requested and issued directly through the
GitHub Security Advisory (GHSA) workflow - no separate MITRE/CNA request is
needed.

## Advisory publication

Published advisories live in **GitHub Security Advisories** on this
repository: https://github.com/byteink/bit/security/advisories

They are also cross-linked from [`docs/release/SUPPORT.md`](docs/release/SUPPORT.md)
(landing via #1748, alongside this file).

A security-relevant fix that also needs a plain-language mention in the next
release's notes (affected versions, observable symptom) stages that text in
[`docs/release/PENDING-NOTES.md`](docs/release/PENDING-NOTES.md) until the
release that carries it is cut - `dist/out/NOTES.md` itself is generated
fresh on every release and is not tracked, so nothing written directly into
it survives past that one release.

## Supported versions

Security fixes are backported only to release lines still under support.
[`docs/release/SUPPORT.md`](docs/release/SUPPORT.md) is the source of truth
for which lines those are and their exact dates (release, full-support-end,
EOL) - this table only summarizes what receives fixes, and is not
duplicated here to avoid drift.

| Line                          | Receives security fixes? |
| ------------------------------ | ------------------------- |
| Latest LTS line                 | Yes, until its EOL date (see SUPPORT.md) |
| Latest interim (non-LTS) release | Yes, until superseded or its support window ends |
| Older / EOL lines               | No - upgrade to a supported line |
| Pre-1.0 (`0.x`)                 | No support guarantee; upgrade-only until v1.0 (#366) activates this policy |

If `docs/release/SUPPORT.md` and this table ever disagree, `SUPPORT.md`
governs.
