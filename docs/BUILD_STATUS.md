# Verification status — 23 October 2026

Applied to the existing PaySME database:
- Existing admin_users staff authorization, without creating or changing staff accounts.
- Voucher lifecycle tables, private recipient/identity/challenge storage, server-only transactional operations, staff read policies and reporting.
- Daily batch job at00:05 Namibia time, preparing only fixed payment orders. No automatic money transfers or voucher release.

Deployed: paysme-vouchers Edge Function. The handler authenticates each operation: real staff JWT, supplier credential, or confirmation token. Dedicated supplier paths cover verify, validate-id, request-otp, validate-otp, redeem and receipt.

Passed:
- Live staff RLS test: existing super administrator allowed; unrelated staff and anonymous users blocked.
- Live rollback-only lifecycle test: sale/payment retries, partial payment rejection, discrepancy hold, contact-change revocation, link expiry, supervisor wrong-code lockout, exact batch release, wrong ID rejection, expired verification, dual OTP, redemption/reprint, supplier isolation and daily batching/deduplication. All test rows rolled back; no real voucher sales were created.
- Live HTTP request to deployed function: an invalid confirmation token returned409 with the expected safe error. No notification was sent. Dedicated supplier calls without a key and staff calls without login returned401; attempted public paid-sale creation returned400. Staff reporting succeeded and unrelated-user reporting was denied.
- Local API/domain/config/server suite:15 passed,0 failed,1 localhost integration skipped; static build and frontend syntax passed. Local HTTP integration is skipped only for this environment's localhost EACCES restriction.
- Security advisor: voucher-related results are informational deny-by-default RLS notices for private tables. No voucher-related warning/error reported. Other existing project findings were outside this change.

Not yet verified: actual browser login/rendering/image upload, external supplier finance/supervisor email delivery, recipient SMS/email delivery, physical printing and parallel stress testing. No production notification was sent. Hosting for public supplier links remains to be configured; the staff portal can be reviewed on localhost.

The Vendor app, its wallets and utilities tables remain untouched. The final wallet purchase and utility-customer integration is a separate next step after portal review. Paid-sale creation is not exposed through the Edge API.

Local preview started and retained at http://127.0.0.1:4173. The server reported a successful bind; this runtime blocks outbound localhost sockets, so HTTP/browser verification from the agent remains unavailable.
