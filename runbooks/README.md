# Organization runbooks

OmniDiag reads approved runbooks from this folder (or from `-RunbookPath` /
`$env:OMNIDIAG_RUNBOOK_PATH`) and uses them for evidence search, the
`Find-OmniRunbook` matches shown after a scan, and the local AI conversation.

Replace or extend these samples with your organization's own procedures. One
Markdown file per runbook, with a front-matter header:

```markdown
---
id: rb-dns-resolution          # stable ID, cited by the AI assistant
title: DNS resolution failures
status: approved               # only 'approved' runbooks are ever used
owner: Network Team
appliesTo: network/dns, dns    # substrings of finding IDs / components
tags: dns, name resolution
---
# Steps...
```

Runbooks are read locally and never uploaded. Keep secrets out of them: they may
be shown to technicians and sent to the local (loopback-only) Ollama model.
