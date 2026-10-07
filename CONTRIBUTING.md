# Contributing to CostcoTracker

Thanks for taking a look at CostcoTracker.

This started as a personal app, so the goal is to keep contributing simple rather than build a giant rulebook.

## Before opening an issue

A useful bug report should include:

- what you were trying to do
- what happened instead
- your iOS version
- the CostcoTracker version
- whether the problem involves warehouse purchases, online orders, price matches, returns, backups, or something else
- any error message that appeared

Screenshots are welcome when they help.

## Please keep personal data out of issues and pull requests

Do **not** post real:

- Costco receipt numbers
- online order numbers
- account/session information
- cookies or tokens
- purchase history
- backup files
- app databases
- personal addresses, phone numbers, or email addresses

If an example needs a receipt, order, barcode, or purchase record, use synthetic data.

## Pull requests

If you want to change something:

1. Fork the repository.
2. Create a branch for the change.
3. Keep the change focused.
4. Build the project before opening the PR.
5. Avoid unrelated formatting or refactors in the same PR.
6. Explain what changed and why.

For UI changes, a screenshot is helpful.

For changes that touch syncing, receipt parsing, returns, price adjustments, backups, or barcodes, include enough detail to explain how you tested it.

## A few behaviors worth preserving

Unless a change is specifically meant to alter one of these rules:

- warehouse receipts and online orders should stay clearly distinct
- synthetic warehouse identifiers should never be displayed as real scannable receipt barcodes
- online orders should show order numbers, not fake warehouse barcodes
- price adjustments should remain separate from purchase and return records
- return quantities are reconciled at the item-number level
- backup restore should validate before touching live data
- a failed restore should roll back cleanly
- destructive bulk actions should ask for confirmation

## Costco changes

Costco can change its website and backend behavior at any time.

If you're fixing a sync issue caused by a Costco change, please avoid committing real account/session data or full personal API responses as fixtures.

Sanitize examples before including them in the repository.

## License

By contributing code to this repository, you agree that your contribution may be distributed under the repository's MIT License.
