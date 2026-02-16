# Noctyra Relay Operator Guide

This document explains relay types, federation setup, and runtime behavior in the Noctyra Relay app.

## 1. Quick Setup
1. Set `Host` and `Port`.
2. Choose `Relay Kind`.
3. Choose `Federation Mode`.
4. Set `Temporal Bucket (minutes)`.
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

Important: kind is descriptive metadata. Forwarding rules are enforced by federation mode and access control.

## 3. Federation Modes (What Is Enforced)
- `solo`
  - No relay-to-relay forwarding.
  - Any request with a destination relay is rejected.
- `curated`
  - Forwarding allowed only to endpoints in allowlist.
  - Destination relay must report `curated` mode.
  - If federation name is set, destination name must match.
- `open`
  - Forwarding allowed without allowlist.
  - Destination relay must report `open` mode.
  - If federation name is set, destination name must match.
  - Open mode cannot use an allowlist.

Note: `open` is intentionally hidden in the current picker UI; it can still be applied through a federation source file.

## 4. Federation Setup from HTTPS JSON
In `Relay Configuration`, set a federation mode other than `solo`, then use `Federation Source (HTTPS)` and click `Fetch Federation`.

Supported JSON fields:
- `mode`: `solo`, `curated`, or `open`
- `name`: federation name
- `description`: federation description
- `allowlist`: list of relay endpoints

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
  ]
}
```

Allowlist parsing rules:
- `host:port` is accepted.
- `https://host[:port]` is accepted.
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
`Temporal Bucket (minutes)` controls timestamp bucketing.

- `0`: disabled
- `1`, `2`, `5`, etc.: bucket size

Larger buckets reduce timing precision but also reduce timestamp granularity in stored metadata.

## 8. What Clients Will See
Clients can read relay metadata from `info`:
- relay kind
- federation mode/name/description
- temporal bucket
- relay name
- operator note
- software version
- whether password is required

This metadata is intended for relay selection transparency.
