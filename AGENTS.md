# PaySME Vouchers

- This repository owns the standalone staff voucher portal and voucher-only SQL migrations.
- Do not edit the PaySME Vendor application or alter its wallet/utilities transaction tables. That integration is separate final-phase work.
- Supplier contacts have no portal accounts. Finance and supervisor approval email addresses must differ.
- Supplier approval contacts and settlement terms are admin-only settings; operators maintain products and branches.
- Preserve integer-cent amounts and purchase-time snapshots in financial phases. Customer discount, supplier rebate and vendor commission are different values.
- Never ship a service-role key, ID number, OTP, confirmation token or customer export in browser code or commits.
- `supabase/migrations/20261023000100_voucher_foundation.sql` is the canonical Phase 1 migration. `node scripts/build.mjs` refreshes its SQL Editor copy in `sql/01_create_voucher_foundation.sql`.
- Run `npm test` and `npm run build`. Real migration/RLS/Storage/Auth checks require a Supabase database; report them separately from local checks.
- Preserve the existing shared PaySME migration history. Do not push local Auth configuration to the shared project.
