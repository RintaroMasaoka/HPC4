# HPC4 connection policy — reference based on ITSO documentation

This file records the parts of HKUST ITSO's published HPC4 connection requirements that this skill relies on. SKILL.md focuses on operations; consult this reference when the policy basis or surrounding context is needed.

## Sources

- [HPC4 - HOW TO LOGIN](https://itso.hkust.edu.hk/services/academic-teaching-support/high-performance-computing/hpc4/login)
- [Off-Campus Wi-Fi Connection for Campus Community](https://itso.hkust.edu.hk/services/general-it-services/wifi/off-campus-wi-fi)
- [HKUST Hotspot Locations](https://itso.hkust.edu.hk/services/general-it-services/wifi/hotspot-locations)
- [Secure Remote Access (VPN) Overview](https://itso.hkust.edu.hk/services/cyber-security/vpn/overview)

Last verified: 2026-04-29. Translation does not constitute a new policy verification.

## Connection paths to HPC4

The ITSO HPC4 login page specifies:

| Location | Required connection |
|---|---|
| **On campus** | Wired connection or eduroam Wi-Fi |
| **Off campus** | Secure Remote Access (VPN) |

The VPN overview identifies **Ivanti Secure Access**, previously named Pulse Secure, as the client. It explains that VPN users receive an HKUST IP address, enabling access to restricted campus resources while away from campus.

The skill's operational model uses `143.89/16` for Ivanti / wired networking and the HKUST campus eduroam internal NAT pool (`10.79/16`), which reaches HPC4 through an internal router. **HPC4 (143.89.184.3) requires a path through HKUST internal networking.**

## What counts as on campus: federated eduroam

ITSO's Hotspot Locations page lists HKUST eduroam coverage within the physical campus: common areas, Shaw Auditorium, catering outlets, the library, teaching venues, offices, laboratories, car parks, and student halls.

eduroam is a federated roaming service. The same SSID is also available at other institutions, including:

- Other universities such as PolyU, CityU, and HKU.
- HKSTP facilities, including **Data Technology Hub at TKO InnoPark**.
- Many airports and railway stations.
- Many universities overseas.

Authenticating with an HKUST account at those locations does not place the client on HKUST's internal network. The visited institution assigns its own IP pool (for example, `172.22/16` at DT Hub), rather than HKUST's `143.89/16` or campus eduroam `10.79/16`. **These connections are off campus for HPC4 access**, so a separate Ivanti VPN connection is required.

Being connected to eduroam alone does not establish HKUST network reachability.

### Mapping to the skill's detection criteria

`scripts/common.sh` functions `find_hkust_iface` and `iface_is_hkust_capable` check for interface IPv4 in `143.89/16` or `10.79/16`, or a `143.89.x` host route through an internal gateway over eduroam NAT. This distinguishes campus connectivity from federated eduroam elsewhere.

| Location / path | Interface IP | Skill result | Policy interpretation |
|---|---|---|---|
| HKUST campus eduroam | 10.79/16 | ok | On campus |
| HKUST wired networking | 143.89/16 | ok | On campus |
| Ivanti SSL VPN from any location | 143.89/16 on utun | ok | Off-campus access via VPN |
| DT Hub eduroam | 172.22/16 | ng | Off campus; Ivanti required |
| Other university eduroam | That university's pool | ng | Off campus |
| Direct home ISP connection | Public IPv4 | ng | Off campus |

## Authentication

The ITSO HPC4 login page describes two methods:

1. **Password + Duo MFA:** enter the username without a domain suffix and the password, then choose a Duo authentication method.
2. **SSH key authentication:** register the public key in `~/.ssh/authorized_keys` to omit both password and Duo prompts.

The skill uses the second method and includes public-key registration through `ssh-copy-id` in its setup flow.

## Use within the skill

Keep the detailed policy rationale here rather than duplicating it in SKILL.md. Agents and users can consult this file when source evidence or surrounding context is needed.
