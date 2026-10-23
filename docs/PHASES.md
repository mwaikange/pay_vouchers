# PaySME Vouchers delivery phases

## 1. Foundation — implemented locally, not deployed
- Staff-only email/password sign-in using existing Supabase Auth plus explicit voucher staff membership; admin-only supplier approval settings.
- Supplier profiles with distinct finance and supervisor emails; branches and towns.
- Products, descriptions, contents, pictures, supplier price, markup, store reference price, rebates and vendor commission.
- Shared provisional customer records and unique customer IDs. No changes to existing utility tables.
- Row-level access controls and an audit trail. Customer records cannot be modified from the browser.
- Acceptance: reviewed migration applies in a disposable test database; anonymous/non-staff/viewer access tests pass; staff can create/edit suppliers, branches and products and upload pictures.

## 2. Voucher records and daily settlement with two-person supplier confirmation
- Batch eligible unbatched paid vouchers per supplier; fixed membership and amounts; Africa/Windhoek cut-off.
- Separate payment orders from actual payment records, allowing top-ups and multiple references.
- Email finance a single-use link; show the batch, payment summary and voucher count.
- Finance requests approval; email supervisor the same batch details plus an expiring, attempt-limited OTP.
- Finance enters supervisor OTP and explicitly confirms. Record both contact snapshots, timestamps and evidence.
- Keep token/OTP hashes server-only, and bind them to batch version and amount.
- Opening a link never changes state. Editing payment details or approval contacts invalidates outstanding challenges.
- Discrepancies hold the batch; PaySME investigates, records resolution and reissues approval. No release on staff resolution alone.
- Full payment confirmation releases exactly the batch's vouchers once, in one database transaction.
- Supplier contacts have no portal accounts. API credentials for redemption are separate from confirmation links.
- Acceptance: replay, expiry, wrong-code limits, amount changes, discrepancy and partial-payment tests; concurrent confirmation releases once.

## 3. Supplier redemption API and receipts
- Supplier-scoped credentials, credential rotation, rate limits and audit logs.
- Verify voucher, validate physical-ID match, request/validate recipient SMS and email OTPs, redeem, retrieve receipt.
- Store identity verification as a short-lived server record tied to the voucher and supplier, not a caller-supplied boolean.
- Redemption is atomic and single-use; payment batch membership is checked as well as supplier ownership and funding.
- Return authoritative receipt fields; supplier decides print layout. Optional 58 mm / 80 mm templates.
- Failed printing/reprints retrieve the same receipt without another redemption.
- All customer-facing support points to PaySME; supplier internal spending slip is its process.
- Acceptance: supplier isolation, simultaneous redemption, failed printing/retry, ID/OTP authorization and masked PII tests.

## 4. Reporting and pilot preparation
- Customer purchasing history across utilities and vouchers; supplier/town/branch analytics and settlement reconciliation.
- Opt-in promotional audiences, support tools and operational monitoring.
- Prepare a test-data pilot with one supplier and end-to-end payment confirmation. Live Vendor app integration comes last as separate work.

## 5. Vendor app purchases and customer linkage — separate final work
- Inspect deployed wallet RPCs/functions and ledger behavior before choosing integration points.
- Vendor is seller; one end-customer/recipient per voucher. No separate purchaser profile.
- Collect recipient name, mobile, email, ID and town; preserve purchase-time snapshots, including chosen collection branch.
- Keep sensitive ID data server-only; never expose raw IDs through lookup or analytics.
- Create sale, wallet debit and voucher atomically with a unique retry key, using integer cents.
- Store rebate timing and net supplier obligation separately; rebate received later is not deducted from today's payment.
- Normalize utility mobile formats; dry-run historical linking; mark imported contacts unverified and report ambiguous cases.
- Marketing defaults off. Explicit opt-in before promotions.
- Acceptance: retry and concurrent purchase tests cause one debit and one voucher; insufficient funds causes neither; no existing utility purchase regression.

## Decisions still requiring integration evidence
- Existing wallet debit mechanism, vendor commission posting and refund/reversal behavior.
- Email and SMS provider credentials, sender identities and public confirmation URL.
- Supplier redemption integration details; product bundle versus store credit entitlement per product.
- Supplier settlement terms, rebate treatment, branch restrictions and cut-off agreed commercially.

## Deployment facts
- Source repository: https://github.com/mwaikange/pay_vouchers
- Existing PaySME project reference: zvoqrqdnuupdefsuiurt. Confirm that project in the SQL Editor before running scripts.
- Apply numbered SQL Editor scripts manually; no live migration, wallet or Vendor application changes have been made.
- The staff portal runs as static files; package installation is not required for local build/preview.
