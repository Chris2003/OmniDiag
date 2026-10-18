---
id: rb-vpn-connectivity
title: VPN connects but resources are unreachable
status: approved
owner: Network Team
appliesTo: network/vpn, network/proxy
tags: vpn, remote access, tunnel, split tunnel, proxy
---
# VPN connects but resources are unreachable

1. Note the VPN profile and connection state from the OmniDiag VPN findings.
2. Verify internal name resolution over the tunnel (see runbook `rb-dns-resolution`).
3. Check for a conflicting proxy (OmniDiag Proxy Configuration findings); WinHTTP and user proxy must match policy.
4. Disconnect, run **Renew IP Address** from the Repair Center, reconnect, and retest.
5. Escalate to the Network Team with the before/after comparison (`-CompareWith Last`) attached.
