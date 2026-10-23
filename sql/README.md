# Voucher database setup

Project: zvoqrqdnuupdefsuiurt (existing PaySME database).

The foundation (01) is already installed. Do not rerun it. Script 05 connects the portal to the existing admin_users staff directory, without changing staff records or Auth accounts. Script 02 is deprecated and now only reports staff setup counts.

For a new installation, run 01, then 05. For the existing installation, apply only 05. Run 03 for read-only verification and 04 for the rollback-only permission test. Live deployment status is recorded in docs/BUILD_STATUS.md.

Staff use their existing Auth email and password. Active, fully set up super_admin staff have administrator access. Other staff require explicit booleans under permissions.vouchers: read (viewer), write (operator), manage_suppliers (administrator). Write and administrator permissions imply read. Existing KYC/vendor permissions do not grant voucher access.

The legacy paysme_voucher_staff table remains for migration history but no longer grants access. Staff permissions are managed through the existing trusted staff administration process, never through this browser portal.

Administrators manage suppliers and approval emails. Operators maintain products and branches. Viewers only read. RLS enforces access. Browser users cannot change customer verification, marketing consent or audit events.

Catalogue images are public JPEG/PNG/WebP up to 5 MiB. Never upload identity documents. Prices are integer cents: supplier500 + markup20 = customer520; reference600 means saving80. Rebates and commissions remain separate.

Sales, settlement and redemption are later phases. Do not apply the unreviewed lifecycle draft migration. Existing utilities, wallets and the Vendor app are outside this phase.
