# oc-mobile-workflows

Built mobile apps of [ObservableCommerce](https://github.com/atatus/ObservableCommerce) and the Maestro flows that drive
them, kept in a public repo so mobile simulations run on public GitHub runners. The app source stays private; this repo
holds only build output and flows. No build carries a service URL or a key: both are passed at launch.

## Layout

```
.
├── manifest.json            # every published build: app id, stack, artifact, ABIs, size, sha256, source commit;
│                            # "store" says whether builds are committed (repo) or assets of the builds release
├── .github/workflows/
│   └── simulate.yml         # run the flows on emulators against the live services
├── scripts/
│   ├── simulate.sh          # install one app, loop its flows in random order for N minutes, or run one long journey
│   ├── fetch-build.sh       # put the app's build in place: from git, or downloaded from the builds release
│   └── mask-secrets.sh      # mask the flux token and seed password in the output before it is uploaded
└── apps/
    └── <app>/
        ├── android/<app>.apk  # x86_64 release build, debug-signed, for emulators only
        ├── ios/<app>.app.zip  # arm64 iOS simulator build, unsigned (merchant, shopper)
        └── maestro/           # the app's flows: config.yaml, common/, journeys/, failures/
```

| App | Persona | Stack | Atatus SDK | Platforms here |
|---|---|---|---|---|
| `shopper` | Customer | Flutter | yes | Android |
| `warehouse` | Warehouse stock ops | Kotlin + Jetpack Compose | yes | Android |
| `courier` | Delivery driver | React Native | no | Android |
| `manager` | Store manager | Compose Multiplatform | no | Android |

| `merchant` | Seller | SwiftUI | yes | iOS |

`shopper` also ships an iOS build. iOS builds come from the private repo's `mobile-ios` workflow (macOS runner); an
app's `ios/` folder appears once a build has been fetched.

## Running a simulation

`simulate` runs one Android emulator per app (x86_64 `google_apis`, Pixel 7, KVM on `ubuntu-latest`), installs the
app's APK and loops that app's flows in random order for the given minutes against `OC_BASE_URL`
(`https://<base>/<service>-service`). A flow that fails because the emulator dropped the device is retried once; any
other failure is recorded as a result, since backend errors and chaos are part of the simulation. The job summary lists
every flow run, and the Maestro output (with failure screenshots) and the emulator's full `logcat.txt` (where the
Atatus SDK logs what it sends) are kept as the `maestro-<app>` artifact for 7 days.

`ios_apps` adds one job per iOS app on `macos-26`: it boots an iPhone simulator, installs `apps/<app>/ios/<app>.app.zip`
and loops the same flows, keeping the app's simulator log as `device.log` in the `maestro-ios-<app>` artifact. A flow whose Maestro iOS driver
fails to start or dies mid-run (no failed step) is retried once. The flux token and the seed password are masked as
`***` in every artifact before upload.

### Long journeys

`long_app` adds one **long journey**: one app launch, one sign-in, then flows back to back in the same app session
for `duration` minutes, so the app sends one long RUM session instead of one short session per flow. It takes
`android:shopper`, `android:warehouse`, `ios:merchant` or `ios:shopper` (the apps with the Atatus SDK). That app runs
in its own job with the same name and artifact as a short job (`android / <app>`, `maestro-<app>`; `ios / <app>`,
`maestro-ios-<app>`), and the plan job drops it from `apps` / `ios_apps`, so it never also runs short. A run may carry
only a long journey (`apps=none`). The other apps loop their flows for the same `duration`, so every job ends
together. `flows` and `include_failures` apply only to the short jobs.

| `long_kind` | What the job does |
|---|---|
| `work` (default) | Runs `common/launch.yaml` and `common/login.yaml` once. Then, until `min(5 min, duration / 5)` before the end, it picks a flow (about 80% from `journeys/`, about 20% from the non-fatal `failures/`: every one except the crash flow), runs it with `MAESTRO_LONG=true` and waits 3–15 s (80% of waits) or 20–90 s (20%) with the app open. It ends with `common/flush.yaml`. A flow tagged `short-only` (shopper's `register.yaml`, which signs out and continues as a new user) is never picked |
| `boot-crash` | Runs the app's crash flow once (`failures/native-crash.yaml` for shopper, `failures/crash.yaml` for warehouse and merchant): launch, crash, relaunch so the SDK uploads the report, flush |

With `MAESTRO_LONG=true` each app's `common/launch.yaml` does not relaunch: it goes back to the app's root screen
(Android `back`, or the `Back` / `nav.back` button on iOS, while the tab bar is hidden; merchant also closes an open
sheet) and taps the home tab. `common/login.yaml` does not sign out: it signs in only when the app shows it is signed
out. Without the variable both behave as in short mode. The first line of `results.tsv` is
`# mode=<short|long> [kind=<work|boot-crash>] target_minutes=<n>`, and the job summary heading shows the same.
Both jobs time out after 355 minutes, so a 300-minute journey fits with the emulator or simulator start-up. A work
journey's job is green only when at least one picked flow passes; its `common/` rows do not count.

```bash
gh workflow run simulate.yml -f apps="shopper warehouse" -f duration=30            # manual; the control panel uses the same workflow_dispatch
gh workflow run simulate.yml -f apps=none -f ios_apps=merchant -f duration=5       # iOS only
gh workflow run simulate.yml -f apps="courier manager" -f long_app=android:shopper -f duration=60   # a 60-minute shopper journey beside short courier and manager loops
gh workflow run simulate.yml -f apps=none -f long_app=ios:merchant -f long_kind=boot-crash -f duration=5
gh api repos/<owner>/oc-mobile-workflows/dispatches \
  -f event_type=simulate -F client_payload[apps]="courier" -F client_payload[duration]=15   # repository_dispatch alternative
```

| Input / payload key | Default | Meaning |
|---|---|---|
| `apps` | `shopper warehouse courier manager` | Android apps to run, one emulator each, in parallel; `none` runs none |
| `ios_apps` | empty | iOS apps to run (`merchant`, `shopper`), one simulator each on a macOS runner |
| `duration` | `30` | minutes for the whole run (1–300): each short app's loop and the long journey's target |
| `long_app` | empty | one long journey: `android:shopper`, `android:warehouse`, `ios:merchant` or `ios:shopper`; removed from `apps` / `ios_apps` |
| `long_kind` | `work` | `work` or `boot-crash` (see [Long journeys](#long-journeys)) |
| `include_failures` | `true` | also run the deliberate-failure flows (backend errors, slow screens, crashes); short jobs only |
| `flows` | all | regex on the flow path, e.g. `journeys/` or `checkout|browse`; short jobs only |
| `api_level` | `35` | emulator API level (35, 34 or 33) |

Repository settings:

| Name | Kind | Required | Value |
|---|---|---|---|
| `MAESTRO_SEED_PASSWORD` | secret | yes | password of the seeded users the flows sign in as |
| `ATATUS_LICENSE_KEY` | secret | for RUM | the platform's flux ingest token (`oc_flux_…`, not a real Atatus key); without it shopper and warehouse still drive the backend |
| `OC_BASE_URL` | variable | no | default `https://qa.atatus.com` |
| `ATATUS_ENV` | variable | no | environment tag, default `simulation` |

Courier and manager have no Atatus SDK; they only generate backend traffic.

Mobile RUM, logs and session replay go to `OC_BASE_URL/flux` (`/flux/v1/android/*`, `/flux/v1/ios/*`), where the gateway admits only
requests carrying the gate token and hands them to the platform's telemetry proxy, which sends them to every
configured Atatus account with that account's real key.

## Updating

This whole repo is generated by ObservableCommerce and never edited here: its files come from
`platform/rum-workflows-repo/` there, and the next sync overwrites any change made here. It is written to
`../oc-mobile-workflows` beside the ObservableCommerce checkout (`MO_WORKFLOWS_DIR` overrides):

```bash
# in ObservableCommerce
make mo-sync                                     # copy these files, build every Android app, copy APKs + flows, update manifest.json
make mo-sync-push                                # the same, then commit (asks for the message) and push this repo
make mo-sync-push MO_SYNC_APPS=courier           # one app
make mo-sync-push MO_SYNC_BUILD=0                # reuse the APKs already built (flow or workflow change)
make mo-sync-push MO_SYNC_APPS=none              # no APK build: publish an iOS build
make mo-sync-push MO_BUILD_STORE=repo            # commit the builds here instead of the builds release (=release switches back)
make mo-ios                                      # iOS: build merchant + shopper on a macOS runner, download the .app builds here
```

To host it in your own GitHub account, run `make mo-sync` once, then here:
`git init -b main && git add -A && git commit -m "initial import" && gh repo create <owner>/oc-mobile-workflows --public --source . --push`,
then `make mo-sync-push MO_SYNC_BUILD=0` in ObservableCommerce to upload the builds.

With `"store": "release"` in `manifest.json` the builds are not in git: each one is an asset of this repo's `builds`
release, named `<app>-<sha256[:12]>.<ext>` and listed as `release_asset`, and every `simulate` job downloads the one
its `manifest.json` names and checks the sha256 before installing it. With `"store": "repo"` they are committed under
`apps/`.

`manifest.json` records the ObservableCommerce commit each APK was built from and whether that app's source had
uncommitted changes (`source_dirty`).

## Running a flow locally

The APKs are x86_64 only, so they install on an x86_64 emulator (or the ObservableCommerce `maestro-android` image),
not on a phone. Each flow reads its service URLs from `MAESTRO_*` variables, for example:

```bash
maestro test apps/courier/maestro/journeys/track-parcel.yaml \
  -e MAESTRO_USER_SERVICE_URL=https://qa.atatus.com/user-service \
  -e MAESTRO_SHIPPING_SERVICE_URL=https://qa.atatus.com/shipping-service \
  -e MAESTRO_ORDER_SERVICE_URL=https://qa.atatus.com/order-service \
  -e MAESTRO_SEED_PASSWORD=<seeded user password>
```
