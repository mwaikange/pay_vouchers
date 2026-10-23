# Voucher build status

Phase 1 implemented: staff login, supplier approval contacts, branches/towns, product contents, pricing and catalogue pictures, plus a read-only shared customer directory.

Live database verification (23 October 2026):
- Confirmed the foundation tables already exist from the SQL previously run by the user. They were not recreated.
- Inspected existing admin_users and its own-row staff RLS. Applied reuse_existing_staff migration, connecting voucher authorization to that directory. No staff records or Auth accounts were created or changed.
- Active, fully set up super_admin staff get full access. Other staff require explicit vouchers permissions; KYC permissions alone do not grant access.
- Live rollback-only test passed: existing super administrator created/read a test supplier; unrelated staff could not see it or create suppliers; anonymous callers had neither RPC access nor supplier SELECT grants. Test data was rolled back.
- Voucher authorization functions use SECURITY INVOKER, empty search paths and authenticated-only execution. Post-change security advisor reported no voucher-specific findings.

Local checks: domain/config/server tests, JavaScript syntax and static build. Local HTTP integration is skipped only when this environment refuses localhost connections with EACCES. Browser login, visual QA and image upload remain unverified because browser control is unavailable.

Not implemented: voucher sale execution, wallet debit, batching/payment operations, dual-email confirmation, discrepancy resolution, redemption APIs and receipt printing. The local lifecycle schema file is an unreviewed draft, not applied or part of the published auth fix. Do not run all local migrations blindly.

The Vendor application, utilities tables and wallets remain unchanged. The portal source is in the pay_vouchers GitHub repository; production hosting has not been set up.
