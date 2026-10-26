# Vendor purchase integration — 23 October 2026

The Vendor app source is `mwaikange/paysme_vendor_app`. Its Utilities screen now has **PaySME Vouchers** directly below **Bets & Gaming**. The flow is supplier → product → recipient details → review → process. Recipient details include the name required by the existing identity snapshot, mobile, ID number, email and a town selected from the shared directory. A planned collection branch is optional.

## Wallet process inspected

- The existing account top-up discount already compensates the vendor. There is **no additional voucher commission**. New voucher sale snapshots record zero, even if an older product has a nonzero commission setting. The portal commission field is fixed at zero.
- `vendors.token_balance` is the main vending balance. The existing `transfer_vendor_utilities_wallet` operation moves money into `vendors.utilities_wallet_balance`, retains the configured minimum main balance, and links the transfer in both histories. Its current implementation supports active prepaid and credit vendors.
- Water/electricity and VAS purchases lock the vendor row and reserve Utilities funds before calling an external provider. Uncertain provider outcomes retain funds until reconciliation; confirmed failures use the existing refund operation. Those provider and refund paths are unchanged.
- A PaySME voucher has no external vend step. `paysme_vendor_voucher` locks the same vendor row, validates the catalogue price and active town, creates the customer association, sale, voucher and private recipient identity snapshot, debits the Utilities wallet, and records linked Utilities history in one database transaction. An error rolls back all of it. It does not debit the main balance or credit the fee balance.

## Towns and identities

`public.namibian_towns` is authoritative; 76 active towns were present during verification. Both the Vendor selection list and portal branch dropdown load active names from this table. A staff read policy permits existing voucher staff to load the list. The purchase function rejects names outside the active list.

Raw IDs are used only to compute the existing private keyed fingerprint and last four characters. They are not stored on the device or in Utilities history, sale rows, logs or receipt responses. Mobile matches create provisional customer links; they do not prove identity or grant marketing consent. Historical utility rows are not backfilled by this change.

## Retry and receipt handling

The device saves only one UUID purchase reference before sending a purchase. The reference binds to the vendor, product, quoted price, recipient details, ID fingerprint, town and optional branch. Matching retries return the original sale and code without another debit; changed details are rejected. A catalogue change cannot reprice a successful retry. The server obtains the vendor from validated Auth; supplied actor, vendor, amount, paid or commission overrides are discarded.

A lost response opens a status screen and retains the reference across restarts. It does not offer a new purchase while the outcome is unknown. Utilities history opens the original purchase receipt. Purchase success means payment was recorded; the voucher remains `awaiting_settlement` until the existing supplier confirmation transaction releases it. No premature activation or automatic bank transfer is introduced.

## Deployment and checks

- Applied to the existing shared database: `20261023145648_paysme_vendor_vouchers`, maintained in the Vendor repository. Do not duplicate or reapply it in this portal repository.
- Deployed the existing `vendor-utilities` function as version 68, retaining platform JWT verification and existing provider code. Supplier logos are saved through the portal to the existing catalogue image bucket and returned with the supplier list. Product cards display the first portal product picture without cropping.
- Rollback-only SQL checked exact wallet debit, zero commission, linked customer/sale/history, identical retries, changed-detail rejection, original pricing after catalogue changes, receipt recovery, invalid contacts/ID/town/branch/price, insufficient balance, cross-vendor isolation and full rollback after a deliberately failed final history insert. No test rows or balance changes remained.
- The existing rollback-only voucher lifecycle test passed: settlement, discrepancies, exact release, ID/dual OTP and redemption/reprints.
- The new purchase RPC is executable by `service_role` only. The private purchase-link table retains deny-by-default RLS; its no-policy advisory is informational. No new warning/error was reported for these new objects.
- All 61 targeted Vendor/API/screen tests passed, including supplier logos, product pictures, town selection, double-tap protection and recovery after reopening. Android export and portal build passed. Portal tests passed 16 with one environment-only localhost skip. Physical-device layout and a real recipient/printer delivery pilot remain separate checks. No paid purchase or production notification was made during development.

The app source and portal static build must be released through their existing deployment processes before all users see the interface changes. Existing APKs do not gain a new screen merely because the backend was deployed.
