# ADR 0009: One office authority, presence service and LiveKit for all members

The default member mode is now `MONASTACK_WORKSPACE_MODE=shared`. A member remains a local authenticated entry point but forwards office API requests to its master. `/v1/workspace` remains local discovery metadata and `/v1/nodes/*` remains the node-enrollment/directory control plane. Existing account/admin forwarding continues in both modes.

The master alone owns business records, room access decisions, realtime tickets and the media room lifecycle. Tickets obtained through any member advertise the master's realtime service, so presence and media token issuance use the same epoch and room namespace. A shared member forcibly disables its own embedded realtime even if `MONASTACK_REALTIME=embedded` was supplied. Clients connect directly to the shared realtime and LiveKit endpoints. No second LiveKit or media credential is needed on members.

`tools/local_office.py` runs one master on 47830, one member proxy on 47840, one shared realtime on 47831 and one LiveKit on 7880/7881/7882. Client realtime 47841 and client LiveKit 7890/7891/7892 are no longer started. The old client media configuration is preserved on disk. The existing server LiveKit config remains `runtime/media/server/`.

Proxy requests preserve the user's authorization and request path/query, enforce a 1 MiB request-body bound, disable system proxies and redirects, and allow 65 seconds for OpenAI chat versus 5 seconds for ordinary requests. If the master is unreachable, shared office requests return 502 rather than reverting to divergent member data. Existing member records are preserved without automatic migration; backups were taken before changing the current local deployment.

`MONASTACK_WORKSPACE_MODE=identity` retains the previous independent-record behavior for explicit legacy tests. Default application authentication and room authorization remain enforced by the master. This change retains the existing same-machine/SSH-loopback endpoint model; it does not introduce remote URL discovery or TLS configuration.

Validation: disposable shared master/member HTTP test checks the same authority, common realtime URL, mutual presence, chat persistence only on the master, room denial and master outage. Opt-in native `shared_media_test.dart` connects two real LiveKit peers through master/member login paths with capture disabled and checks mutual participants and presence.
