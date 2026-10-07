# CostcoTracker

CostcoTracker is an iPhone app I built because Costco receipts are useful right up until you actually need to find something in them.

It keeps your Costco purchase history in one place, lets you look up what you paid before, helps spot possible price matches, keeps track of things you may want to return, and gives you a cleaner way to pull up receipt info when you're standing in the warehouse.

It started as a personal project for me. I'm open-sourcing it because it may be useful to other people too.

> **CostcoTracker is unofficial. It is not affiliated with, endorsed by, sponsored by, or maintained by Costco Wholesale Corporation.**

## What it does

### See what you bought and what you paid

CostcoTracker can sync warehouse purchases and online orders, then lets you search by Costco item number.

For an item, you can see things like:

- when you bought it
- where you bought it
- what you paid
- how many you bought
- whether it was a warehouse purchase or online order
- receipt or order information
- recorded price adjustments
- recorded returns

The purchase history screen also rolls the numbers together so you can see total purchased quantity, returned quantity, net quantity, gross purchase spend, average price per unit, lowest and highest recorded prices, and a price history chart.

### Check for price drops

If you're in Costco and see something you already bought sitting there for less, enter or scan the item number and current shelf price.

CostcoTracker compares that against your saved purchase history and shows the difference.

If it looks worth dealing with, save it to the **Price Matches** tab so you can keep a running list while you're walking around the store.

You can also save a clean price-match card to Photos if you want the receipt details handy.

Costco still gets the final say on whether an adjustment is actually allowed. The app is there to help you find the purchase and do the math, not pretend to be the Costco policy department.

### Keep track of returns

The **Returns** tab is a holding area for things you may want to bring back.

You can save a purchase, add a product photo, and keep the receipt information with it.

For warehouse purchases, CostcoTracker can show the actual receipt barcode when one is available.

For online orders, it shows the order number instead. It does not make up a fake warehouse barcode.

### Back up your stuff

There is a built-in backup and restore feature under **Data** on the Scan screen.

A backup can include:

- receipt and purchase history
- price adjustments
- return information
- Price Match Queue
- Saved Returns
- saved return photos
- sync state

Backups use the `.costcotrackerbackup` file extension.

Costco login cookies and web-session data are intentionally left out.

## Install with SideStore

Add this source to SideStore:

```text
https://raw.githubusercontent.com/diggitydogg/CostcoTracker/main/source.json
```

Once the source is added, CostcoTracker should show up like any other SideStore app and future builds can be installed as updates.

If you're using a free Apple developer account, remember that SideStore itself counts toward Apple's active-app limit.

## Quick start

### 1. Install the app

Install CostcoTracker from the SideStore source above and open it.

The app may ask for:

- **Camera access** for scanning
- **Photos access** for saving receipt and price-match cards

### 2. Sync your Costco history

Run a sync before doing much else.

The first sync may take a bit because CostcoTracker is pulling in older purchase history. After that, later syncs are much quicker.

### 3. Check an item

On the **Scan** tab:

1. Enter or scan the Costco item number.
2. Enter the current shelf price.
3. Run the price check.

If you only want to see old purchases and don't care about the current shelf price, enter the item number and choose **View Purchase History**.

### 4. Save a price match

If a price difference looks interesting, save it.

It will show up in the **Price Matches** tab with the important purchase details.

Swipe left to delete one.

Use **Clear All Price Matches** when you're done with the whole list. Clearing this list does not touch your actual receipt history.

### 5. Save a return

Find the purchase you want and save it to **Returns**.

You can add a photo if that helps you remember what the thing actually is.

Swipe left when you no longer need it.

Use **Clear All Saved Returns** if you want to wipe the whole list. That also removes the return photos stored inside CostcoTracker.

Anything you deliberately saved to the normal Photos library stays there.

### 6. Pull up a receipt

If CostcoTracker has the actual warehouse receipt barcode, you can open it full screen for easier scanning.

Warehouse purchases and online orders are handled differently on purpose:

- warehouse purchase = receipt barcode when available
- online purchase = order number

### 7. Make a backup

Go to **Data** and choose **Back Up CostcoTracker**.

Save the file somewhere you trust.

I would especially make a backup before:

- moving to a new phone
- deleting or reinstalling the app
- testing a major new build
- doing anything else that feels like it might become an annoying story later

### 8. Restore a backup

Go to **Data** → **Restore CostcoTracker** and pick your `.costcotrackerbackup` file.

The app validates the backup before replacing anything.

If restore fails partway through, CostcoTracker is designed to roll back to the data you had before the restore started.

You may need to sign back into Costco afterward because login/session data is not part of the backup.

## Building it yourself

There are currently no third-party Swift package dependencies. The project uses Apple system frameworks and SQLite.

1. Clone this repository.
2. Open `CostcoTracker.xcodeproj`.
3. Select the `CostcoTracker` scheme.
4. Pick your iPhone as the run destination.
5. Set your own signing team as needed.
6. Build and run.

The SideStore releases in this repository are built automatically with GitHub Actions. The IPA is built unsigned and SideStore handles device signing.

## A few things worth knowing

### This is not an official Costco app

Costco can change its website, receipt formats, APIs, or policies whenever it wants.

If they change something important, syncing may need to be fixed in a future build.

### Price-match results are not guarantees

CostcoTracker can tell you what you paid, what the current price is, and what the difference looks like.

Whether Costco actually approves an adjustment is still up to Costco.

### Returns are reconciled by item number

The return data available from Costco does not always tell the app exactly which original purchase receipt a return belongs to.

Because of that, return quantities are reconciled at the item-number level.

### Your data is local

The working database lives on your device.

Backup files can contain detailed purchase history, so treat them like personal data and store them somewhere sensible.

## Releases and updates

New builds are published from this repository.

GitHub Releases contain the built `CostcoTracker.ipa`, and the repository's `source.json` is updated automatically so SideStore can see new versions.

## Contributing

This started as a one-person personal project, so parts of the project structure and documentation are still catching up with the code.

Issues and pull requests are welcome.

Please do not post real Costco receipt numbers, order numbers, account/session information, or personal purchase data in issues, PRs, logs, screenshots, or test fixtures. Synthetic examples are much better.

See [CONTRIBUTING.md](CONTRIBUTING.md) for a few basic ground rules.

## License

CostcoTracker is open source under the [MIT License](LICENSE).

You're free to use, modify, and redistribute the code under the terms of that license.

The Costco name and Costco trademarks are not part of that license.

## Why I made this

I wanted a better way to answer questions like:

- Did I already buy this?
- What did I pay last time?
- Did this get cheaper?
- Which receipt was that on?
- How many of these did I actually keep?
- What was I planning to return?

If it happens to be useful to somebody else too, great.

## Disclaimer

Costco, Costco Wholesale, and related marks belong to Costco Wholesale Corporation.

CostcoTracker is an independent, unofficial project. It is not affiliated with, endorsed by, sponsored by, or maintained by Costco Wholesale Corporation.

Double-check Costco's current policies before relying on the app for price adjustments, returns, or anything else Costco ultimately gets to decide.
