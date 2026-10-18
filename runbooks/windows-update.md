---
id: rb-windows-update
title: Windows Update failures
status: approved
owner: Endpoint Engineering
appliesTo: system/updates, system/servicing, cloud/updaterings
tags: windows update, patch, servicing, sfc, dism
---
# Windows Update failures

1. Confirm the update ring / policy from the OmniDiag Update Rings findings.
2. Run **DISM RestoreHealth**, then **SFC Scan** from the Repair Center (admin, restore point created).
3. If updates still fail, run **Reset Windows Update Components** and reboot.
4. Re-scan and compare. Escalate to Endpoint Engineering with the report package if unresolved.
