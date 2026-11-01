# CostcoTracker Analytics cloud sync (iOS client)

CostcoTracker can upload its purchase history to the owner's own [CostcoTracker Analytics](https://github.com/diggitydogg/CostcoTracker-Analytics) deployment. The default deployment is `https://costcotracker-analytics.pages.dev`.

Uploads use the Analytics Export V1 contract and the sync protocol.

**Never uploaded:**
- Costco credentials, cookies and sessions
- receipt barcodes
- online order numbers

## Architecture

```
CostcoTracker/AnalyticsSync/          (compiled into the app AND the test package)
  AnalyticsIDs.swift                  deterministic export IDs (HMAC-SHA256, idKey)
  AnalyticsSourceSnapshot.swift       read-only SELECTs from the existing SQLite tables
  AnalyticsExportModel.swift          Export V1 record types (explicit nulls)
  AnalyticsExportBuilder.swift        source rows → Export V1 (pure)
  AnalyticsBatchPlanner.swift         receipt/transaction units, batches, change hashes, manifest
  AnalyticsAPIClient.swift            device + sync endpoints, error envelope
  AnalyticsUploader.swift             start → batches → complete; retry, resume, abort
  AnalyticsCredentialStore.swift      Keychain secrets, UserDefaults metadata, upload-state files
  AnalyticsCloudSync.swift            coordinator: connect, decide mode, upload, requests, status
CostcoTracker/AnalyticsCloudAppSupport.swift   shared instance + background refresh registration
CostcoTracker/AnalyticsCloudSettingsView.swift Data → CostcoTracker Analytics screen
Package.swift + Tests/AnalyticsSyncTests       `swift test` harness (not linked into the app)
```

### Hooks in existing code
These are additive only. The Costco sync engine (`CostcoSyncView`) and `DBManager` are unchanged.

- **`CostcoTrackerApp.swift`**
  - registers the background task;
  - on every `scenePhase == .active`, resumes interrupted uploads and checks website requests;
  - schedules background refresh when the app goes to the background.
- **`ContentView.swift`**
  - tells the coordinator when the Costco sync sheet opens and closes;
  - shows a one-line notice when the website asked for fresh data.
- **`BackupRestoreView.swift`**
  - adds a "CostcoTracker Analytics" entry to the Data screen;
  - notifies the coordinator after a restore.
- **`Info.plist`**
  - `BGTaskSchedulerPermittedIdentifiers`: `com.danmcgoldrick.CostcoTracker.analytics-refresh`;
  - `UIBackgroundModes`: `fetch`.

### When uploads happen
| Trigger | Mode |
|---|---|
| The Costco sync sheet closes and **both** warehouse and online refreshed (their own success timestamps advanced) | full if due, otherwise incremental |
| Only **one** source refreshed (partial Costco sync) | incremental only, never full |
| "Sync to Analytics" button | full if due, otherwise incremental |
| A website request while Costco data is fresh (both sources refreshed within 6 h) | full if due, otherwise incremental, and it fulfils the request |
| Launch / foreground / background refresh | resume an interrupted upload; answer requests |

**Incremental** sends only receipts (each with its complete item set) and return/adjustment transactions whose content hash changed since the last successful upload.

**Full** sends everything plus a manifest of every receipt, return and adjustment ID.
- **Cadence:** at most once every **7 days**.
- **When:** only after a fully successful Costco refresh (or a manual sync), with online history backfill complete. Never after a partial refresh.
- **What the server does:** tombstones cloud records that are no longer on the phone. If that would remove more than 20% (or more than 50 rows), it holds them for review on the website.
- **Local data:** the app never deletes local or analytics history itself.

### Website "Refresh from Costco" requests
The Costco refresh is interactive: a signed-in web view in the Costco sync sheet. It cannot run silently, and the phone cannot be woken instantly.

When the app finds a pending request (on launch, foreground, after a Costco sync, or in best-effort background refresh), it:
1. **acknowledges** it, so the website shows that the phone picked it up;
2. if Costco data on the phone is **fresh**, uploads immediately with `requestId`, which fulfils the request;
3. otherwise shows "CostcoTracker Analytics asked for fresh data…" under the sync button. The next successful Costco sync uploads with `requestId`.

A manual upload with stale Costco data does **not** claim to fulfil the request.

### Upload protocol
| Step | Endpoint | Behaviour |
|---|---|---|
| Start | `POST /api/sync/runs` | Lower-case UUID `runId`, `formatVersion` 1, USD, `requestId` or null. Idempotent per `runId`, so it is also the resume entry point. |
| Send | `PUT /api/sync/runs/:id/batches/:seq` | Up to 200 rows and about 240 KB per batch. A receipt always travels with all its items, and a return/adjustment transaction always travels whole. |
| Complete | `POST /api/sync/runs/:id/complete` | `{batchCount, manifest?}`. On `409 missing_batches`, the listed batches are resent once. |
| Abort | `POST /api/sync/runs/:id/abort` | Only when the server rejected data. Never for transient errors. |

**Exact resends.** Batch bodies are persisted as exact bytes in `Application Support/AnalyticsCloudSync/inflight-run.json`, which is excluded from device backups. A resend is therefore byte-identical, and the server replays it instead of applying it twice.

**Retry.** Network errors, 429 and 5xx are retried after 1 s, 3 s and 8 s. If they persist, the plan stays on disk.

**Resume.** On the next launch or foreground, `GET /api/sync/runs/:id` lists the received batches, and only the missing ones are sent. If the run expired on the server, the plan is dropped and a fresh one is built.

**Revoked token.** A 401 clears the token and shows "disconnected by website; create a new code".

## Exact ID derivation

```
token(domain, p1, p2, …) = first 22 chars of base64url( HMAC-SHA256( K, domain ␀ p1 ␀ p2 … ) )
```

- `K` is the **32 raw bytes** decoded from the server's base64url `idKey`. An `idKey` that doesn't decode to 32 bytes is rejected.
- `␀` is a single U+0000 separator. The message is UTF-8.
- base64url has no padding.

| Record | ID |
|---|---|
| receipt | `"r_"` + token(`"receipt"`, `receipts.barcode`) |
| item | `"i_"` + token(`"item"`, `items.receipt_barcode`, `items.item_number`, occurrence) |
| return | `"ret_"` + token(`"return"`, `item_returns.transaction_barcode`, `item_returns.item_number`) |
| price adjustment | `"adj_"` + token(`"adjustment"`, `price_adjustments.transaction_barcode`, `price_adjustments.item_number`) |
| transaction | `"t_"` + token(`"transaction"`, transaction_barcode) |

**Source keys.** `receipts.barcode` is used as stored, whatever it holds: a real receipt barcode, a synthetic `WHSE_<date>_<warehouse>` key, or an online order key. It is never uploaded itself.

**Item occurrence.** `occurrence` is the decimal 0-based index of the row among rows of the same receipt with the same item number, ordered by SQLite rowid.
- Warehouse receipts hold one row per item number, so it is always `"0"` there.
- Online orders can repeat an item number.
- It is counted before invalid rows are filtered out, so a row becoming valid never renumbers its siblings.

**Stability.** Identifiers depend only on natural keys and `K`, never on SQLite row IDs. So they stay stable across:
- repeated syncs;
- CostcoTracker re-syncing a receipt (which deletes and re-inserts its items);
- reinstalling the app;
- a second or replacement iPhone, because the server hands every device the same `idKey`.

### Test vectors
`idKey = AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8`, which is bytes `00 01 … 1f`.

| Input | ID |
|---|---|
| receipt `99990000000000000001` | `r_YWpAbbf-K7axt_A1igxbiT` |
| receipt `WHSE_2026-01-18_SYNTHETIC_SOUTH` | `r_pVjhKpKG_Gi0IRNjakVJWN` |
| receipt `SYNTH-ORD-1001` | `r_JtTAM_CQZknqFzL4qG86wh` |
| item `SYNTH-ORD-1001`, `9000005`, `0` | `i_3ckliMeuGWUPEHnYjirtCi` |
| item `SYNTH-ORD-1001`, `9000005`, `1` | `i_zaHdQhNsKZ4BxxjZnJsWdO` |
| return `99990000000000000101`, `9000005` | `ret_dY5ASGlgIzdnEDCCrDgpnG` |
| adjustment `99990000000000000101`, `9000005` | `adj_T8j2MYQXn2wUPJ8HMDysOj` |
| transaction `99990000000000000101` | `t_rri_VXEabecuic6gZsDan8` |
| receipt `ünïcødé ✓` | `r_T28yu6DJd2ul1I8FLqQdnn` |

The raw check `base64url(HMAC(K, "receipt␀abc"))` = `BzCsDQ1_ui1Pz1Auf1ck89-29UX-2Ngk-DOFjMY9MEQ`.

The vectors and the golden export come from `Tests/AnalyticsSyncTests/Fixtures/make-golden.mjs`. It is an independent Node implementation using `node:crypto`. The Swift tests must reproduce its output exactly, and the golden export was validated with the Analytics importer and sync-batch validator.

## Field mapping (Analytics Export V1)

| Export field | Source | Rule |
|---|---|---|
| receipt `sourceType` | `receipts.warehouse` | `online` if it starts with `Online Order`, otherwise `warehouse` |
| receipt `identifierKind` | `receipts.barcode` | `onlineOrderKey` (online) / `synthesizedWarehouseKey` (`WHSE_…`) / `transactionBarcode` |
| `purchaseDate`, `returnDate`, `adjustmentDate` | date columns | a real `YYYY-MM-DD` date, otherwise null |
| `warehouse`, return `description`, `transactionType` | text columns | null when missing or blank; otherwise verbatim (including the placeholder `Warehouse`) |
| item `description` | `items.description` | verbatim (may be `""`) |
| item `lineTotalCents` | `unit_price × quantity` | round-half-away-from-zero of × 100, which is the stored net line total |
| item `unitPriceCents` | `unit_price` | integer cents only when the price is a whole number of cents, otherwise null |
| return `merchandiseAmountCents`, `transactionTotalCents` | REAL dollars | integer cents or null |
| adjustment `amountCents`, `transactionTotalCents` | REAL dollars | integer cents (required) |
| adjustment `referenceLineNumbers` | `reference_line_number` | split on `,`, trimmed, empty entries dropped |
| `sourcePurchaseId` | none | always null: the database never knows the original purchase |

**Transaction totals** are whole-transaction values. They are repeated on each row of the transaction and are never summed or split by the app.

**Excluded rows.** Rows that can't be represented validly are left out and counted by reason; they are never guessed. The reasons are:
- orphan items;
- missing item numbers;
- non-positive quantities;
- negative amounts;
- transactions whose rows disagree on date, warehouse, type or total;
- units too big for a batch.

The settings screen shows how many were skipped.

## Secrets, metadata and backup/restore

| Data | Where | Survives relaunch | In CostcoTracker backup | Moves to a new iPhone |
|---|---|---|---|---|
| `deviceToken` | Keychain, `AfterFirstUnlockThisDeviceOnly` | yes | **no** | **no**; re-enroll with a new code |
| `idKey` | Keychain, `AfterFirstUnlockThisDeviceOnly` | yes | **no** | **no**; the server returns the same `idKey` on re-enrollment |
| `deviceId`, device name, last upload/error, last full check, pending request, server URL | UserDefaults (`analytics_cloud_*`) | yes | **no** (not in `BackupManager.backedUpDefaultsKeys`) | no |
| upload hash cache, in-flight run | Application Support (excluded from device backups) | yes | no | no |

### Why
- **A device token is a per-device bearer credential.** Copying it to another phone would make two devices share one identity, and the website couldn't revoke one without the other.
- **A replacement phone instead re-enrolls with a new one-time code.** It gets its own token and the same server-held `idKey`, so every export ID is identical and the cloud sees no duplicates. A test covers this.
- **The `idKey` stays stable** because the server keeps it. It doesn't depend on the phone or on backups.
- **Metadata without Keychain secrets is treated as "not connected".** This happens after migrating to a new phone, for example, and the metadata is cleared.
- **Restoring a backup on the same phone** keeps the connection. The upload cache and any interrupted run are discarded because they describe the replaced data. The next upload re-sends everything, and unchanged rows cost nothing on the server.

**Disconnect** (Data → CostcoTracker Analytics → Disconnect) deletes the Keychain items, metadata and upload state on the phone. The device can't revoke its own token on the server, so also remove the iPhone on the website.

## Privacy and logging
- **Never uploaded:** Costco usernames, passwords, cookies, session or bearer tokens, raw receipt barcodes, `WHSE_` keys and order numbers. Uploads contain only Export V1 fields and opaque IDs. The Analytics server also rejects credential- or barcode-like field names.
- **Never logged:** the device token, the `idKey`, Costco credentials and purchase payloads. `os.Logger` messages carry only events and counts.
- **Error text** shows the server error code, HTTP status and record paths, never purchase values.
- **The device token** is sent only in the `Authorization` header to the configured Analytics origin over HTTPS. Plain HTTP is allowed only for `localhost`, for local testing. The token is never put in a URL.
- **Network session:** an ephemeral `URLSession` with cookies disabled.

## Manual testing (production)
1. **Website:** sign in at `https://costcotracker-analytics.pages.dev`, go to **iPhones** and choose **Create connection code**.
2. **iPhone:** open **Scan → Data → CostcoTracker Analytics**. Check that **Advanced → Server** shows `costcotracker-analytics.pages.dev`.
3. **Connect:** enter the code and an iPhone name, then tap **Connect**. The status should show **Connected**.
4. **Upload:** tap **Sync to Analytics**. The first upload is a full check if online history is backfilled.
5. **Website:** **Sync** shows the run, and **Overview** shows the counts.
6. **Request test:** on the website choose **Refresh from Costco**. On the iPhone, bring the app to the foreground or run **Sync Latest Costco Purchases**. The website request should change to *iPhone is syncing* and then *Done*.
7. **Debug actions:** **Advanced** has **Run Full Check Now** and **Check for Website Requests**. It also shows the device ID, last full check and last run status. No secrets are shown.
8. **Local backend** (`npm run dev:cloud` in the Analytics repo): while disconnected, set **Advanced → Server URL** to `http://localhost:8788`. This works in the Simulator.

## Running the tests
```bash
swift test
```

It runs on macOS. It compiles `CostcoTracker/AnalyticsSync` as a module, using the app's Swift settings.

CI (`.github/workflows/ios-ci.yml`) runs `swift test` and an unsigned iOS build on every pull request and every non-`main` push. It never publishes.
