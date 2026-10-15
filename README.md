# oc-mobile-workflows

Built mobile apps of [ObservableCommerce](https://github.com/atatus/ObservableCommerce) and the Maestro flows that drive
them, kept in a public repo so mobile simulations run on public GitHub runners. The app source stays private; this repo
holds only build output and flows. No build carries a service URL or a key: both are passed at launch.

## Layout

```
.
├── manifest.json            # every published build: app id, stack, artifact, ABIs, size, sha256, source commit
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
