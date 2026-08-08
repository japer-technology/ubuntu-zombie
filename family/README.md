# Family data contract

This directory is the only source shared by independently installed AI-agent
products. It contains data schemas and the release catalogue; it contains no
runtime Python or shell code.

`catalog.json` remains empty until a product release has passed its checksum,
SBOM, provenance, signature, and disposable-VM gates. A source implementation
is not a production catalogue entry.

The normative contract is
[`docs/ai-agent/implementation.md`](../docs/ai-agent/implementation.md).
