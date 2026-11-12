# Agott sync

Keeps routines, the days they were done (with the reps counted as proof) and your API keys the same
on the Mac, the iPhone and the Apple Watch, so each one works on its own.

Everything is encrypted on the device before it leaves. The Worker stores opaque ids and
ciphertext in one SQLite Durable Object per person, and never sees routine names, dates or keys.

- **Key:** your passphrase → PBKDF2-HMAC-SHA256 (600 000 rounds, random salt kept on the Worker)
  → HKDF-SHA256 → an AES-256-GCM key and a naming key. The passphrase is never stored or sent;
  each device keeps the derived key in its Keychain.
- **Records:** id = HMAC of the record's real name; data = AES-GCM with the id as associated data,
  so the Worker can't read, rename or swap records. `test/format.test.ts` opens a record the
  Swift apps sealed, with plain WebCrypto.
- **Auth:** a bearer token per person, kept as the `AGOTT_TOKENS` secret. With no tokens set, the
  Worker refuses everything.

## Deploy

```bash
cd sync-worker
npm install
npm test
```

```bash
npx wrangler login
```

```bash
npx wrangler deploy
```

Make a token (keep it somewhere safe, like your password manager):

```bash
openssl rand -base64 32
```

Give it to the Worker (paste it when asked; for more people, separate tokens with commas):

```bash
npx wrangler secret put AGOTT_TOKENS
```

The deploy prints the address, like `https://agott-sync.<you>.workers.dev`.

## Pair your devices

1. **Mac:** Settings → Connections → Sync. Type the address, the token and a passphrase (at least 8
   characters; a long sentence is best). The first device to connect sets up the vault; your
   routines, done days and API keys go up.
2. **iPhone:** Settings → Sync, the same address, token and **the same passphrase**. A different
   passphrase is refused. Routines show in the Today tab, and notifications nag you at their time.
3. **Apple Watch:** nothing to type. Once the iPhone is connected it hands the Watch the address,
   token and derived key (not the passphrase) over the Watch's own encrypted link. Open Agott on the
   Watch once.

Counting: on the iPhone, Today → Start counts with AirPods (Pro, Max, or 3rd generation and later);
on the Watch, Start counts from the wrist in a workout session that also goes into Health. Reaching
90 % of each exercise's reps (from the routine's steps, like "3x10 flexões") proves the day; steps
without reps (planks, stretching) are ticked by hand.

Health: every counted workout is saved to Apple Health as functional strength training, each set as
one of its activities (exercise and reps), with heart rate and energy when it comes from the Watch.
Today → Progress on the iPhone reads them back (plus the sets synced from other devices) and shows,
per exercise, reps per set, seconds a rep, rest, reps per minute, heart rate and the trend against
your last workouts.

## Forgot the passphrase?

There is no way back into encrypted data. Wipe the vault and connect again, Mac first:

```bash
curl -X DELETE -H "Authorization: Bearer $TOKEN" -H "X-Agott-Confirm: wipe" https://agott-sync.<you>.workers.dev/v1/vault
```

Then Settings → Sync → Disconnect on each device, and connect with the new passphrase.

## Develop

`npm test` runs the Worker in workerd with vitest. To try it by hand, copy `.dev.vars.example` to
`.dev.vars` and run `npm run dev`.

API (all but health need `Authorization: Bearer <token>`):

| Method and path | What it does |
|---|---|
| `GET /v1/health` | `{ ok, service: "agott-sync", version }` |
| `GET /v1/meta`, `PUT /v1/meta` | Salt, rounds and a sealed check value; set once by the first device (409 with the existing one after that) |
| `GET /v1/records?since=N` | Changes after cursor `N`, oldest first, 500 a page, with `cursor` and `more` |
| `PUT /v1/records/:id` | `{ data, base }`: written if `base` is the current version (0 for new), else 409 with the current record |
| `DELETE /v1/records/:id?base=N` | Leaves a tombstone other devices see |
| `DELETE /v1/vault` | Wipes everything; needs `X-Agott-Confirm: wipe` |

## Limits

- The iPhone silences its reminders when it syncs: when you open Agott, or when iOS wakes it in the
  background (every 20 minutes at best, at iOS's discretion). A day done on the Watch may still
  ring the phone once or twice before that.
- Rep counting is tuned on synthetic motion (`AgottTests/WorkoutSyncTests.swift`); real recordings
  from the Watch and AirPods should be used to tune it further. Pull-ups count best with AirPods,
  since the wrist stays on the bar.
