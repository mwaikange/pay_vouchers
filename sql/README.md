# Voucher SQL

The existing PaySME project zvoqrqdnuupdefsuiurt already has the foundation and all voucher migrations through daily batching applied. You do not need to run these scripts again.

For a fresh installation only:01 foundation,05 existing staff access,06 lifecycle tables,07 transactional operations/reporting/daily batching.02 is deprecated.03 and09 are read-only verification;04 and08 are complete rollback-only integration tests.08 never sends messages or moves money.

Canonical migrations are under supabase/migrations.07 combines the operations, operational-controls and daily-batching migrations for SQL Editor use. Never apply both a numbered script and its canonical migration to the same database.

Existing staff Auth email/password are used. Active completed super_admin staff have full access; other staff need explicit permissions.vouchers read/write/manage_suppliers booleans. Suppliers have no portal accounts. The legacy paysme_voucher_staff table is retained but no longer authorizes access.

Financial tables allow staff reads through RLS and no direct browser writes. The command RPC is service-only. Recipient snapshots, HMAC key, challenges and supplier key hashes are private with no client grants. Catalogue images alone are public; never upload identity documents.

No Vendor app, wallet, utilities table or Auth configuration is changed. Do not deploy the local Auth config to the shared project. See docs/OPERATIONS.md and docs/SUPPLIER_API.md.

Migration history: the foundation was applied manually before connector access and is not registered in Supabase migration history. Later migration filenames match the server-recorded versions. Do not run `supabase db push` or rerun the foundation against this shared project until that baseline is reconciled through a reviewed migration procedure. No migration-history records were changed.
