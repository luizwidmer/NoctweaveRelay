# Noctyra Relay Operator Guide

This document explains relay types, federation setup, and runtime behavior in the Noctyra Relay app.

## 1. Quick Setup
1. Set `Host` and `Port`.
2. Choose `Relay Kind`.
3. Choose `Federation Mode`.
4. Set `Temporal Bucket (minutes)` and optional `Multi-Bucket Schedule (minutes)`.
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

Important: kind is descriptive metadata. Forwarding rules are enforced by federation mode and access control.

## 3. Federation Modes (What Is Enforced)
- `solo`
  - No relay-to-relay forwarding.
  - Any request with a destination relay is rejected.
- `curated`
  - Strict policy is enabled by default.
  - Forwarding requires:
    - destination endpoint in allowlist
    - destination seen as healthy by coordinator quorum
    - signed coordinator directory when `Require Signed Directory` is enabled
  - Destination relay must report `curated` mode.
  - If federation name is set, destination name must match.
- `open`
  - Forwarding allowed without allowlist.
  - Destination relay must report `open` mode.
  - If federation name is set, destination name must match.
  - Open mode cannot use an allowlist.

Note: `open` is available in the relay app UI and via federation source files.

## 4. Federation Setup from HTTPS JSON
In `Relay Configuration`, set a federation mode other than `solo`, then use `Federation Source (HTTPS)` and click `Fetch Federation`.

Supported JSON fields:
- `mode`: `solo`, `curated`, or `open`
- `name`: federation name
- `description`: federation description
- `allowlist`: list of relay endpoints
- `coordinators`: list of coordinator endpoints (`host:port`, `https://host:port`, or `wss://host:port`)
- `coordinatorHeartbeatSeconds`: relay heartbeat interval to coordinators
- `curatedStrictPolicyEnabled`: optional bool (`true`/`false`)
- `curatedCoordinatorQuorum`: optional integer (`>=1`)
- `curatedRequireSignedDirectory`: optional bool (`true`/`false`)

Example:
```json
{
  "mode": "curated",
  "name": "Noctyra-Curated",
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
- `https://host[:port]` and `wss://host[:port]` are accepted.
- If URL port is omitted, relay defaults to `9339`.

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
- Curated relay-to-relay forwarding can use coordinator directory lookups as an allow source only when strict policy is disabled.
- In strict mode, static allowlist membership is always mandatory.

Open federation discovery acceleration:
- Non-coordinator open relays may advertise peer hints (`knownOpenPeers`) in relay info.
- Clients merge coordinator directory + peer hints to bootstrap additional open relays faster.
