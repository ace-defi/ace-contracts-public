# Security Policy

## Scope

This repository is a source snapshot of production ACE V5 and its bound Lucky
Draw V3 instances on HyperEVM mainnet (chain ID 999). The supported deployments
are listed in the [README](README.md#production-deployments). Earlier version
numbers in imported filenames identify dependencies, not additional supported
deployments. The broader public verification input is described in the README.

Source publication, successful compilation and source verification do not
constitute a security certification. See the README's
[trust model and known limitations](README.md#trust-model-and-known-limitations).
Reports of additional impacts or ways to bypass the stated boundaries are welcome.

## Report a vulnerability privately

Email **official@ace.pro** with a subject starting with `Security report:`.
Do not disclose an unmitigated exploit in a public issue, pull request, discussion
or social media post. Please include:

- The affected repository commit, contract address and chain ID.
- A description of the issue, required conditions and potential impact.
- Reproduction steps or a minimal proof of concept on an isolated local chain
  or fork; do not exploit a live deployment.
- Relevant transaction hashes or other non-sensitive evidence, if available.
- A contact method for follow-up.

Never send private keys, seed phrases, production credentials or unrelated
personal information. Do not access other users' data, move their funds, disrupt
services, or test against live contracts without separate explicit authorization.

## Coordinated disclosure

Please coordinate any public disclosure with the project while the report is
being investigated and mitigations are considered. No response deadline, bounty,
reward or permission for live exploitation is promised by this policy. A source
or documentation update alone does not change an already deployed contract.
