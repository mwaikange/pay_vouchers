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

The public staff screens do not permit identity-data edits, verification overrides, batch membership edits, direct voucher activation or manual marking of a sale as paid. Paid-sale registration is an internal-only database operation reserved for the final atomic Vendor wallet integration. There is no exposed Edge route that can fabricate a paid sale.

## Monitoring and checks

The daily job is `paysme-voucher-daily-batches` in Supabase Cron. Its schedule is `5 22 * * *` UTC, equivalent to 00:05 Namibia time. Review `cron.job_run_details` for failed runs. To pause it through trusted SQL: `select cron.alter_job((select jobid from cron.job where jobname='paysme-voucher-daily-batches'), active := false);`.

Run `sql/09_verify_operations.sql` for read-only deployment checks and `sql/08_test_voucher_lifecycle.sql` for the rollback-only test. The test never sends email/SMS or moves money. It exercises pricing snapshots, retries, partial payments, discrepancy holds, contact revocation, link expiry, supervisor lockout, exact release, identity checks, verification expiry, dual OTP, redemption/reprint, supplier isolation and daily batching. It simulates sequential contention outcomes; parallel load testing remains outstanding.

Identity fingerprints use a random database-private HMAC key. Raw ID numbers are never stored in voucher tables. Recipient contact snapshots and OTP/token digests are in a private schema without API grants or client RLS policies. The private schema's informational 'RLS enabled, no policy' advisory is intentional deny-by-default behavior. Never grant browser access to these tables.

No production supplier notification has been sent during development. A real email/SMS delivery pilot and browser/printer checks are still required before a live launch. Vendor app changes, wallet debits, utilities history linking and promotional audiences remain the explicitly separate final phase.
