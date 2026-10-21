# oc-mobile-workflows

Built mobile apps of [ObservableCommerce](https://github.com/atatus/ObservableCommerce) and the Maestro flows that drive
them, kept in a public repo so mobile simulations run on public GitHub runners. The app source stays private; this repo
holds only build output and flows. No build carries a service URL or a key: both are passed at launch.

## Layout

```
.
├── manifest.json            # every published build: app id, stack, artifact, ABIs, size, sha256, source commit
├── .github/workflows/
│   └── simulate.yml         # run the flows on emulators against the live services
├── scripts/
│   └── simulate.sh          # install one app, loop its flows in random order for N minutes
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
committed APK and loops that app's flows in random order for the given minutes against `OC_BASE_URL`
(`https://<base>/<service>-service`). A flow that fails because the emulator dropped the device is retried once; any
other failure is recorded as a result, since backend errors and chaos are part of the simulation. The job summary lists
every flow run, and the Maestro output (with failure screenshots) and the emulator's full `logcat.txt` (where the
Atatus SDK logs what it sends) are kept as the `maestro-<app>` artifact for 7 days.

```bash
gh workflow run simulate.yml -f apps="shopper warehouse" -f duration=30            # manual
gh api repos/<owner>/oc-mobile-workflows/dispatches \
  -f event_type=simulate -F client_payload[apps]="courier" -F client_payload[duration]=15   # what the control panel sends
```

| Input / payload key | Default | Meaning |
|---|---|---|
| `apps` | `shopper warehouse courier manager` | apps to run, one emulator each, in parallel |
| `duration` | `30` | minutes of flows per app (1–300) |
| `include_failures` | `true` | also run the deliberate-failure flows (backend errors, slow screens, crashes) |
| `flows` | all | regex on the flow path, e.g. `journeys/` or `checkout|browse` |
| `api_level` | `35` | emulator API level (35, 34 or 33) |

Repository settings:

| Name | Kind | Required | Value |
|---|---|---|---|
| `MAESTRO_SEED_PASSWORD` | secret | yes | password of the seeded users the flows sign in as |
| `ATATUS_LICENSE_KEY` | secret | for RUM | turns Atatus mobile RUM on in shopper and warehouse; without it they still drive the backend |
| `OC_BASE_URL` | variable | no | default `https://qa.atatus.com` |
| `ATATUS_SITE` | variable | no | `us`, `in` (default) or `eu` |
| `ATATUS_SERVER_URL` | variable | no | overrides the site's intake URL |
| `ATATUS_ENV` | variable | no | environment tag, default `simulation` |

Courier and manager have no Atatus SDK; they only generate backend traffic.

## Updating

Builds are published from the private repo, never edited here:

```bash
# in ObservableCommerce, with MO_WORKFLOWS_DIR=<this clone> in .env.secret
make mo-publish                                  # build every Android app, copy APKs + flows, update manifest.json
make mo-publish MO_PUBLISH_APPS=courier          # one app
make mo-publish MO_PUBLISH_BUILD=0               # copy the APKs already built
gh workflow run mobile-ios.yml --ref <branch>    # iOS: build merchant + shopper on a macOS runner
make mo-ios-fetch                                # then download that run's .app builds here
```

Then review the diff here, commit and push. `manifest.json` records the private repo's commit each APK was built from
and whether that app's source had uncommitted changes (`source_dirty`).

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
