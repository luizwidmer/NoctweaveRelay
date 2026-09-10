# Third-Party Notices

## coturn

The native relay app includes a minimal arm64 build of coturn 4.17.2 to provide
optional STUN/TURN call traversal. coturn is distributed under its BSD-style
license. The complete license text is included inside
`ManagedCoturn.bundle/Contents/Resources/LICENSE` and is also available from
the [coturn project](https://github.com/coturn/coturn).

Noctweave's managed build disables coturn database integrations, TLS/DTLS,
OAuth, Prometheus, and SCTP; its generated configuration disables the CLI.
Noctweave application-layer media encryption remains independent of coturn.
The rebuild recipe is `Scripts/build-managed-coturn.sh`; its matching debug
symbols and build record are retained in `Symbols/` for archive uploads and
crash symbolication.
