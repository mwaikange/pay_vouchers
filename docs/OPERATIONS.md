# Voucher operations

Staff use their existing PaySME Auth login. The current `admin_users` directory controls access. Active completed super admins can manage suppliers, finance operations and supplier API keys. Other staff require `permissions.vouchers.read`, `write`, or `manage_suppliers`. No new staff memberships or supplier accounts are created.

## Daily settlement

At **00:05 Namibia time**, the database prepares one payment order per active supplier with eligible unbatched paid vouchers through the previous Namibia calendar day. It includes missed older unbatched sales as well. It does not transfer money, send emails or release vouchers. The unique voucher membership prevents the same voucher entering multiple batches. Staff can also prepare an earlier batch manually using an explicit Namibia cutoff.

1. Review the fixed vouchers and amount under Settlements.
2. Make the bank transfer through PaySME's existing banking process.
3. Record the bank reference and actual amount. Multiple payment records can top up a batch; the same bank reference cannot fund another batch.
4. Once the recorded total covers the amount due, send the finance contact a confirmation link.
5. Finance checks the payment and requests the supervisor code. The supervisor receives the batch details and an expiring approval code at the distinct registered supervisor email.
6. Finance obtains the code, enters it and explicitly confirms receipt of the payment. The database settles the batch and releases exactly its vouchers in one transaction.

Overpayments remain visible as unallocated credit on that batch; they do not activate other vouchers. Settlement consumption uses the contractual supplier amount, not the customer's price or the in-store reference price. A product with an immediate rebate reduces supplier due; a rebate payable later does not reduce today's settlement.

Confirmation links last 48 hours. Supervisor codes last ten minutes, with five attempts and five sends maximum per link and a 60-second resend cooldown. A successful confirmation consumes its link. Payment additions and approval-contact changes invalidate outstanding links; staff must issue a fresh link.

The portal must be hosted at a shareable HTTPS URL before finance emails can be sent. The sender uses that portal URL and a token in the URL fragment, so the token is not sent as an ordinary page query or referrer. Opening the link only loads details; it never confirms payment or sends an OTP. The confirmation page has no account sign-in requirement.

## Discrepancies

Finance reports payment not received, amount mismatch, reference mismatch or another issue through its link. The batch moves to disputed and its vouchers stay on hold. PaySME investigates and records the resolution, adds any legitimate payment top-up, then sends a fresh supplier confirmation. Recording a resolution alone never releases vouchers. All relevant records retain their timestamps and contact snapshots.

## Redemption and receipts

Issue a supplier server credential, optionally restricted to a store. The supplier verifies the voucher, checks the physical ID or completes both recipient OTPs, redeems once and prints the returned receipt. The receipt is immutable; retries and reprints do not consume additional funding. See [supplier API](SUPPLIER_API.md).

The public staff screens do not permit identity-data edits, verification overrides, batch membership edits, direct voucher activation or manual marking of a sale as paid. The authenticated Vendor purchase action atomically debits its existing Utilities wallet and creates the sale/voucher/history. It pays no extra commission because the vendor already benefits from the account top-up discount. Staff and supplier routes cannot fabricate a paid sale. See [Vendor integration](VENDOR_INTEGRATION.md).

## Monitoring and checks

The daily job is `paysme-voucher-daily-batches` in Supabase Cron. Its schedule is `5 22 * * *` UTC, equivalent to 00:05 Namibia time. Review `cron.job_run_details` for failed runs. To pause it through trusted SQL: `select cron.alter_job((select jobid from cron.job where jobname='paysme-voucher-daily-batches'), active := false);`.

Run `sql/09_verify_operations.sql` for read-only deployment checks and `sql/08_test_voucher_lifecycle.sql` for the rollback-only test. The test never sends email/SMS or moves money. It exercises pricing snapshots, retries, partial payments, discrepancy holds, contact revocation, link expiry, supervisor lockout, exact release, identity checks, verification expiry, dual OTP, redemption/reprint, supplier isolation and daily batching. It simulates sequential contention outcomes; parallel load testing remains outstanding.

Identity fingerprints use a random database-private HMAC key. Raw ID numbers are never stored in voucher tables. Recipient contact snapshots and OTP/token digests are in a private schema without API grants or client RLS policies. The private schema's informational 'RLS enabled, no policy' advisory is intentional deny-by-default behavior. Never grant browser access to these tables.

No production supplier notification has been sent during development. A real email/SMS delivery pilot and physical-device/printer checks remain. New Vendor voucher purchases link customer, sale and Utilities history atomically. Historical utility backfill and promotional audiences remain separate. The purchase code is shown in the app and history; this change does not send purchase SMS/email.

## Customer and company views

Customers is exclusively for the PaySME voucher programme. The staff-only directory includes profiles with voucher-sale records; VAS-only profiles are excluded. Select a customer to open their contact profile, lifetime voucher purchase counts, paid voucher value and redeemed count, plus paginated voucher history across supplier companies. The history shows sale number, product, supplier, voucher/status, collection town/store, payment order and receipt. Refunded/cancelled records remain visible; paid value counts only sales currently marked paid. The list masks mobile numbers; the staff-only individual record shows contact details. Raw IDs and OTPs are never included.

Sales, Settlements and Reports default to All companies. Selecting a company applies a shared filter across these three tabs; select All companies to restore the combined view. Inactive suppliers remain selectable for historical review. Lists load up to 1,000 records after supplier filtering; report totals and planning include the full selected dataset. Company changes hide the old rows while the new results load. Customer pages are independent of that finance filter and always show that customer's voucher history across companies.

The additional read-only migration is sql/10_voucher_customer_company_views.sql (already applied). sql/11_test_customer_company_views.sql is its complete rollback-only integration test. No wallet, Vendor app or existing transaction-writing function is modified by this change.


## Proof of payment and resending

Record bank payments with a PDF, JPEG, PNG or WebP POP up to 5 MB. For older payments, use Upload POP beside the existing bank reference; do not enter another payment. Full payment and a POP for every payment are required before Send confirmation becomes available. Resolve open disputes first. Until OTP confirmation settles the batch, finance confirmation can be resent. Each resend revokes earlier links; use the newest email and request a fresh supervisor code. POPs are private attachments in finance and supervisor emails, with temporary viewing links on the confirmation page. SMTP acceptance is distinct from inbox delivery; check Spam/Junk if a message is accepted but absent.
