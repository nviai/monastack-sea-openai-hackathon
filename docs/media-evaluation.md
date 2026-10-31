# Media evaluation (not implemented)

LiveKit is a candidate, not a configured capability. Its [Flutter SDK](https://docs.livekit.io/transport/sdk-platforms/flutter/) supports room connections and microphone control, but the SDK call alone does not enforce Monastack membership. The trusted authority would need to issue room-scoped tokens only after checking the actor and room, and actively remove participants when membership or room changes.

A material limitation is that, according to LiveKit's [token lifecycle documentation](https://docs.livekit.io/frontends/reference/tokens-grants/), self-hosted participant removal does **not** invalidate an already issued token. A short token lifetime narrows the rejoin window but does not provide immediate revocation, and expiration does not disconnect a participant already connected. Removing someone from a room and relying on expiry therefore does not by itself meet the requested private-room boundary. An authorization-enforcing media gateway or another design with a tested way to isolate authorized participants immediately is still needed; possible room-epoch rotation requires a concrete design and adversarial testing before use. LiveKit Cloud has a different revocation mechanism, but using a third-party service or sending this workspace's data there has not been authorized.

A complete integration also needs a distinct authenticated media control service, microphone entitlement and permission, default-muted UI, and tests of active removal, unauthorized rejoin, room transitions, reconnect, and server failures. Those components and tests do not exist yet. The local Mac reports an audio input device and Docker is available, but no media service or two-client microphone test has been configured. Do not treat text chat or the presence service as voice.

## Synthetic isolation experiment

On the development Mac, a local experiment used LiveKit server `v1.13.10` and the Python RTC SDK `1.2.0` in containers connected only to a Docker `--internal` network. Random test identities, ephemeral credentials and a generated sine tone were used; no seed, workspace records, microphone, or user credentials entered the test. Two authorized room connections received synthetic audio, and a connection in a different room received none. After the server removed one participant, that participant successfully rejoined the original room with the *same previously issued token* and again received audio. After deleting the old room and moving the publisher plus a new authorized listener to a new room epoch, the authorized listener received the new tone while the stale-token participant remained in the old epoch without receiving it. The SDK logged unexpected data-channel closure while the room was deleted; the test completed and removed its temporary containers and network.

This does **not** establish safe revocation in Monastack. It does not test hostile or disconnected clients republishing into an old epoch, a trusted authority coordinating all publishers, access changes racing with media, microphone capture, the Flutter SDK, or two actual app instances. Creating or deleting a room alone is not a complete policy. A control plane must prevent authorized participants from continuing to publish into an obsolete epoch and must recheck authorization for every newly issued token; adversarial end-to-end testing remains necessary. The app still has no voice capability.

## Synthetic server rotation experiment

A second local-only probe starts two disposable LiveKit servers in an internal Docker network with independent random keys. A synthetic listener first receives a generated tone on the old server. The fixture then forcibly removes that server, verifies old audio stops and that the old token cannot connect to either the removed server or the replacement, and confirms that a newly authorized listener receives audio on the replacement. It retries both the old listener and old publisher tokens after the replacement has demonstrably delivered audio, and verifies that a token for a different room receives no synthetic audio. No workspace records, real credentials or microphone data enter the experiment. The test removes only its own randomly named containers and network.

This establishes a possible isolation mechanism in a controlled synthetic scenario, not a working media control plane or immediate revocation guarantee. It does not verify an authenticated authority, atomic membership-change ordering, fail-closed handling of failed server termination, resource isolation under concurrent room changes, stale endpoint routing, client reconnection, actual microphone permissions, or malicious publishers during a real transition. A production design would have to stop the old instance successfully before issuing replacement credentials, recheck current membership, and prevent clients from publishing to an obsolete endpoint. The app still reports voice unavailable.

`core/src/media.rs` now contains a tested, fail-closed issuance state model for this future control plane. Rotation blocks new issuance until an explicit stop confirmation and activation; stale acknowledgements, a failed rotation, invalid membership, and a freshly denied authorization cannot issue. This in-memory model is **not wired to the node or LiveKit**: it does not authenticate callers, persist or serialize operations, stop a server, rotate secrets, invalidate an already issued token, or prove that a stop confirmation is truthful. Generation numbers are not credentials. A real implementation must supply these missing enforcement and recovery guarantees.

To reproduce with the existing locally built probe image and server image:

```sh
MONASTACK_MEDIA_PROBE_IMAGE="$(docker image inspect monastack-media-probe-20261029:local --format '{{.Id}}')" python3 tools/media-spike/run_rotation_probe.py
```

## Synthetic Flutter/macOS SDK experiment

The locally cached `livekit_client` 2.13.1 SDK was built in a disposable Flutter/macOS project. A separate disposable Flutter test app then opened two SDK room connections to the pinned self-hosted LiveKit server. The authorized connection received RTP bytes for a synthetic silent audio track generated by a Python client; the connection in a different room received no audio track, and the receiver had no local audio publication. Both SDK connections ran within the same app process. The test used random synthetic credentials, no workspace seed or records, no microphone capture, an explicit empty ICE server list, and a bounded TCP relay listening only on `127.0.0.1` into an internal Docker network. The generated silence avoids emitting a test tone through the user's speakers. The server, relay, publisher and temporary project are cleaned up by the fixture. Flutter package resolution is offline; Xcode may fetch public SDK build dependencies if they are not cached.

This proves basic SDK subscription, receipt of synthetic media and one cross-room isolation case on the tested Mac, not audible playback, microphone permission, user voice, comprehensive privacy isolation, Monastack membership enforcement, revocation or Monastack app integration. The relay is test infrastructure, not an authenticated media gateway. Voice remains unavailable in the application.

To reproduce with the local synthetic Python environment and probe image:

```sh
MONASTACK_MEDIA_PROBE_IMAGE="$(docker image inspect monastack-media-probe-20261029:local --format '{{.Id}}')" tools/media-spike/.venv/bin/python tools/media-spike/sdk_loopback_probe.py
```

To reproduce with Docker and the pinned server image already available, from the repository root run:

```sh
probe_image=$(docker build -q --pull=false tools/media-spike)
MONASTACK_MEDIA_PROBE_IMAGE="$probe_image" python3 tools/media-spike/run_probe.py
```

The dedicated Docker build context includes only the synthetic client and pinned dependency list. A first image build may download generic packages; it does not include project records. The runner uses only randomly named test resources and reports cleanup errors. The ephemeral test key is not a production credential. See the official [token lifecycle](https://docs.livekit.io/home/server/generating-tokens) and [room API](https://docs.livekit.io/reference/other/roomservice-api/) documentation for the self-hosted behavior being tested.
