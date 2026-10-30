# Third-Party Notices

## coturn

The native relay app includes a minimal arm64 build of coturn 4.18.0 to provide
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

The helper statically links OpenSSL 3.5.9 LTS (Apache-2.0) and libevent
2.1.13-stable (BSD-style). Their complete licenses are included in
`ManagedCoturn.bundle/Contents/Resources/OpenSSL-LICENSE.txt` and
`ManagedCoturn.bundle/Contents/Resources/Libevent-LICENSE.txt`.
