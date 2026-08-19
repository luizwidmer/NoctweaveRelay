# Noctweave Relay Operator Guide

This document explains relay types, federation setup, and runtime behavior in the Noctweave Relay app.

For the complete Noctweave federation wire protocol, JSON request examples, endpoint parsing rules, and Linux relay recipes, see `../NoctweaveDocumentation/federation_protocol_and_operations.md`.

## 1. Quick Setup
1. Set `Host` and `Port`.
2. Choose `Relay Kind`.
3. Choose `Federation Mode`.
4. Set `Temporal Bucket (minutes)` and optional `Multi-Bucket Schedule (minutes)`, or apply the NoctCord immediate-delivery profile.
5. Choose `Storage` (`Disk` or `RAM`).
6. Optionally set `Relay Password`, `Relay Name`, and `Operator Note`.
7. Click `Start`.

## 2. Relay Kind (What It Signals)
`Relay Kind` is operator metadata exposed to clients via relay info.

- `standard`: general-purpose relay.
- `discovery`: discovery/pairing-focused role.
- `bridge`: federation bridge role.
- `archive`: archival/retention-oriented role.
- `privateRelay`: restricted/private deployment.
- `coordinator`: directory-only node (no client inbox role; advertises relay directory + health view).

Important: kind is descriptive metadata. Federation is an operator-plane discovery and coordination mechanism; it is not a user-message forwarding path.

## 3. Federation Modes (What Is Enforced)
- `solo`
  - No federation discovery or coordination.
- `manual`
  - Publishes only operator-reviewed relay descriptors from the local node list.
  - Descriptors must report `manual` mode and a matching federation name when one is configured.
  - No coordinator, DHT, quorum, or peer exchange is used.
  - The relay may start with an empty node list.
  - Every listed standard relay is probed directly. Adding or removing one
    updates the live directory without restarting the relay.
- `curated`
  - Uses allow lists, coordinator quorum, freshness policy, and optional signed directories to publish a bounded relay directory.
  - Descriptors must report `curated` mode and a matching federation name when one is configured.
- `open`
  - Uses bounded signed discovery records, host quotas, public-endpoint validation, and peer-hint limits.
  - Descriptors must report `open` mode and a matching federation name when one is configured.

Clients learn destination relays from relationship-encrypted route sets and submit ciphertext directly to those opaque routes. Federation requests never carry relationship events or opaque-route packets. `manual`, `curated`, and `open` are available in the relay app UI and via federation source files.

## 4. Federation Setup from HTTPS JSON
In `Relay Configuration`, set a federation mode other than `solo`, then use `Federation Source (HTTPS)` and click `Fetch Federation`.

Supported JSON fields:
- `mode`: `solo`, `manual`, `curated`, or `open`
- `name`: federation name
- `description`: federation description
- `allowlist`: list of relay endpoints. In manual mode this is the complete node list; in curated mode it is the static allowlist.
- `coordinators`: list of coordinator endpoints (`host:port`, `https://host:port`, or `wss://host:port`)
- `coordinatorHeartbeatSeconds`: relay heartbeat interval to coordinators
- `curatedStrictPolicyEnabled`: optional bool (`true`/`false`)
- `curatedCoordinatorQuorum`: optional integer (`>=1`)
- `curatedRequireSignedDirectory`: optional bool (`true`/`false`)

Example:
```json
{
  "mode": "curated",
  "name": "Noctweave-Curated",
  "description": "Trusted relay mesh",
  "allowlist": [
    "relay-a.example.org:9339",
    "https://relay-b.example.org:9443",
    "[2001:db8::10]:9339"
  ],
  "coordinators": [
    "coord-a.example.org:9339",
    "https://coord-b.example.org:9443"
  ],
  "coordinatorHeartbeatSeconds": 45,
  "curatedStrictPolicyEnabled": true,
  "curatedCoordinatorQuorum": 2,
  "curatedRequireSignedDirectory": true
}
```

Allowlist parsing rules:
- `host:port` is accepted.
- `https://host[:port]` is accepted for HTTP relays.
- If URL port is omitted, `https` defaults to `443`, `http` defaults to `80`, and bare TCP defaults to `9339`.
- The macOS relay does not implement WebSocket/WSS listeners; configure those endpoints with the sibling Linux relay.

## 5. Storage Modes
- `Disk`: persists envelopes, prekeys, and attachment data at the selected file path.
- `RAM`: fully ephemeral; state is lost on stop/restart.

Use `Disk` for production relays. Use `RAM` for temporary/testing relays.

## 6. Access Control (Relay Password)
If `Relay Password` is set:
- `info` and `health` remain public.
- Deliver/fetch/pairing/attachment/prekey and similar operational requests require auth.
- Clients must configure the same password in relay settings.

Use a strong random password and rotate it if leaked.

### One-use contact pairing

`Allow one-use contact pairing` enables and advertises
`nw.rendezvous-transport@2` only when the effective transport is confidential:
native Relay TLS or a trusted TLS reverse proxy. It is never advertised as
usable over remote plaintext TCP. The local listener remains plain in reverse-
proxy mode and must be firewalled so clients cannot bypass the trusted proxy.
The service stores only bounded encrypted frames under short-lived
random capabilities. Direct / Offline Pairing transfers those stages by QR or
protected file and therefore does not need this service, although each
participant still needs a standard relay for its private message route.

### Same-relay pairing lobby

`Same-relay pairing lobby` is a separate default-off discovery switch. It is
effective only for a Standard relay with realtime routes enabled and uses the
same confidential-transport gate as rendezvous. A visible client publishes a
fresh signed, session-only badge for at most two minutes; requests, approval,
and the ordinary one-use invitation travel through disposable PQ-encrypted
routes.

The listing is enumerable to every client allowed to use the relay and exposes
timing and traffic metadata, though it contains no persona name or relationship
material. Prefer a relay password and edge rate limits on public deployments.
Listings are process-local, capped at 32, and disappear on relay restart.

### Optional coturn traversal

A standard relay may advertise STUN/TURN through `nw.ice-service@1`. Under
**Transport**, enable **Call connectivity**. The default **Managed** mode starts
the coturn service bundled with the native app, detects a local address,
generates a private TURN REST key, stores it in Keychain, and returns only
short-lived credentials to eligible clients. It starts and stops with the
Noctweave relay.

LAN operation requires no additional service. For Internet operation, forward
the displayed TCP/UDP listening port and UDP allocation range to this Mac. TURN
does not pass through an ordinary HTTPS reverse proxy; use direct forwarding or
a layer-4 proxy. **Advanced call settings** provides public-address overrides,
port controls, and an **External** mode for an operator-managed coturn service.
The TURN service can observe endpoint addresses, timing, and traffic volume,
while call media remains encrypted by the client media transport.

Managed mode does not require the generated coturn configuration in backups.
The app deletes that transient file after launch and can generate a new shared
key if Keychain state is unavailable after restoration. Existing temporary TURN
credentials then expire; relay identity and stored ciphertext are unaffected.
External mode requires the operator to restore the same shared key at both ends.

### NoctCord community profile

The **NoctCord** panel controls four application-neutral relay modules:

- `nw.realtime-route@1`: low-latency encrypted signaling and records.
- `nw.shared-log@1`: bounded, cursor-based opaque community history.
- `nw.ephemeral-presence@1`: expiring online and room-presence leases.
- `nw.media-blobs@1`: bounded encrypted channel media using the relay's normal attachment retention policy.

Use **Apply Recommended Profile** for a NoctCord-capable relay. It selects the
Standard relay kind, disables temporal bucketing, enables all four modules, and
enables attachments. The settings are explicit and may be narrowed afterward.
Disabling temporal bucketing affects every workload on this relay, so operators
who also want timing-obscured messaging should use a separate relay instance.

Remote realtime service advertisement requires native Relay TLS or a trusted
TLS reverse proxy. Plaintext is permitted only for literal loopback development.
Calls and screen sharing additionally need call connectivity under **Transport**.
The native app can manage its bundled coturn service, or an operator can select
an external deployment in advanced settings.

NoctCord community policy remains end-to-end encrypted client state. The relay
does not configure or inspect community names, channels, roles, memberships, or
content, and the native app intentionally exposes no such plaintext controls.

## 7. Temporal Bucket
`Temporal Bucket (minutes)` controls the base timestamp bucketing.
`Multi-Bucket Schedule (minutes)` is an optional comma-separated list (example: `2,5,11`) used for per-message bucket selection.

- `0`: disabled
- `1`, `2`, `5`, etc.: bucket size

Larger buckets reduce timing precision but also reduce timestamp granularity in stored metadata.
Multi-bucketing adds timing diversity across messages and makes simple timing-correlation attacks harder.

## 8. What Clients Will See
Clients can read relay metadata from `info`:
- relay kind
- federation mode/name/description
- federation coordinators (if configured)
- temporal bucket
- multi-bucket schedule (if enabled)
- attachment retention policy (default/max TTL)
- relay name
- operator note
- software version
- whether password is required

This metadata is intended for relay selection transparency.

## 8.1 Attachment Retention
Attachment uploads are ephemeral on relay storage.

- `Attachment Default TTL (minutes)`: applied when sender does not request a TTL.
- `Attachment Max TTL (minutes)`: upper bound; larger requested TTLs are clamped by relay policy.

This prevents unbounded attachment growth and helps control storage cost.

## 9. Coordinator Operation
When coordinator endpoints are configured:
- Relay nodes periodically heartbeat/register themselves to coordinators.
- Coordinators maintain a live directory (healthy relays only).
- Coordinators can return signed directory snapshots (`federationSnapshot`) with freshness windows.
- Clients can keep a direct connection to their home relay and also query coordinator directories to refresh relay lists/health.
- Curated relay discovery can use coordinator directory lookups as a directory source only when strict policy is disabled.
- In strict mode, static allowlist membership remains mandatory for published descriptors.

Open federation discovery acceleration:
- Non-coordinator open relays may advertise peer hints (`knownOpenPeers`) in relay info.
- Clients merge coordinator directory + peer hints to bootstrap additional open relays faster.
