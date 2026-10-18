---
id: rb-dns-resolution
title: DNS resolution failures
status: approved
owner: Network Team
appliesTo: network/dns, network/hosts
tags: dns, name resolution, lookup, hosts file
---
# DNS resolution failures

1. Confirm the symptom: `Resolve-DnsName <internal host>` and `Resolve-DnsName microsoft.com`.
   If only internal names fail, the internal resolver or the DNS suffix list is the likely cause.
2. Compare the configured resolvers (`Get-DnsClientServerAddress`) with the approved list for the site.
3. Check the hosts file finding in OmniDiag; remove only entries you can attribute to a known change.
4. Flush the resolver cache (Repair Center: **Flush DNS Cache**) and retest.
5. If a VPN is connected, test with and without it - split-DNS misconfiguration is common.
6. Escalate to the Network Team with the OmniDiag report if resolvers are correct but lookups still fail.
