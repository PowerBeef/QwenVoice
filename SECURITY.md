# Security policy

## Supported versions

Security fixes are applied to the current source on `main` and, when practical, to the latest
public macOS release. Older releases and development snapshots are not supported security branches.

| Surface | Supported |
| --- | --- |
| Current `main` | Yes |
| Latest signed and notarized macOS release | Yes |
| Older releases and beta snapshots | No |
| iPhone builds distributed outside an official project channel | No |

## Report a vulnerability privately

Do not open a public issue for a suspected vulnerability or include user data, credentials, model
tokens, private audio, prompts, transcripts, absolute paths, device identifiers, or exploit details
in public project content.

Use the repository's **Security** tab and select **Report a vulnerability** to open a private
security advisory with the maintainer. Include the affected version or commit, platform, impact,
and minimal reproduction steps. If private vulnerability reporting is temporarily unavailable,
contact the repository owner privately through their GitHub profile and provide only enough detail
to establish a secure follow-up channel.

The maintainer will acknowledge a complete report when it is reviewed, coordinate validation and a
fix privately, and publish an advisory after affected users have a reasonable update path. Exact
response times are not promised for this maintainer-run project.

## Scope

In scope: the Vocello macOS/iPhone applications, the `vocello` CLI, signed release artifacts,
release automation, model-download integrity, local persistence, XPC boundaries, and the project
website. Upstream vulnerabilities in Qwen, MLX, Apple frameworks, GitHub Actions, npm packages, or
Hugging Face should also be reported to their owners; report them here when Vocello needs a
mitigation or ships an affected version.
