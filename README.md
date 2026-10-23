# PaySME Vouchers

Standalone PaySME staff portal for supplier profiles, approval contacts, branches, product pricing and pictures. This repository is Phase 1 of the voucher platform; live sales, payment confirmation and redemption are not implemented yet.

## Database setup

Run the numbered scripts from [sql/](sql/README.md) in the existing PaySME project's Supabase SQL Editor:

1. [Create voucher foundation](sql/01_create_voucher_foundation.sql) — run once, complete script.
2. [Enroll a staff administrator](sql/02_enroll_staff.sql) — replace the email placeholder with an existing Supabase Auth account.
3. [Verify setup](sql/03_verify_setup.sql) — check tables, RLS, staff and catalogue bucket.
4. [Test staff permissions](sql/04_test_staff_permissions.sql) — optional real access test; all test writes are rolled back.

These scripts do not alter existing utility transaction tables, wallet balances or Auth configuration. They create seven new application tables and voucher-specific helper functions, access policies, triggers and a product-picture bucket. Customer history is linked during the final Vendor app phase.

## Run the portal

Node.js 22 or newer is sufficient. There are no npm packages to install.

```sh
npm run dev
```

Open `http://127.0.0.1:4173` in Chrome. The official, version-pinned Supabase client is loaded from its CDN and requires browser internet access. The public project URL/anon key are in `config.js`; optional `.env.local` overrides use the names in `.env.example`. Only public keys are allowed; build/serve reject service-role and secret keys in their configuration.

The server binds to localhost and exposes only the portal assets; it does not expose `.env` files, SQL files or project scripts. It is a development preview, not a production application server.

```sh
npm test
npm run build
npm run preview
```

The build creates static files in `dist/` for a normal static host. It also refreshes the numbered SQL creation script from the canonical migration in `supabase/migrations/`.

## Access and behavior

- Staff sign in using Supabase Auth, then must have explicit, active `paysme_voucher_staff` membership. There is no public signup or frontend staff enrollment.
- Admins manage suppliers and their two approval emails. Operators maintain products and branches. Viewers have read-only access. RLS enforces these rules in the database, independently of UI buttons.
- Supplier finance and supervisor emails must differ. These are contact details, not supplier Auth accounts. The email/OTP payment-confirmation flow is a later phase.
- Customer profiles have unique internal IDs. Initial phone matching is provisional and is not identity verification. Browser staff cannot modify verified status, marketing consent or customer identity data.
- Public catalogue pictures are JPEG/PNG/WebP up to 5 MiB. IDs and personal documents do not belong in this bucket.
- Prices use integer cents. N$500 supplier base + N$20 markup = N$520 customer price; an N$600 store reference gives an N$80 saving. Immediate rebates reduce the settlement amount; later rebates and vendor commission remain separate values.
- Products distinguish specified bundles from store credit. A store-credit product must declare its credit value independently of the customer's purchase price.
- Catalogue records can be deactivated, not deleted through the portal. Audit events record changed field names and the acting staff user without copying customer details into audit payloads.
- Lists load up to 250 suppliers, products and branches, 1,000 image records, and the latest 100 customer profiles. Displayed counts are loaded-record counts, not platform-wide financial analytics.

## Delivery order

1. Staff portal, suppliers, branches, catalogue and shared customer table.
2. Voucher records, payment batches, two-email confirmation and discrepancy handling.
3. Supplier redemption endpoints and receipt data.
4. Reporting and test-data pilot.
5. Vendor app and wallet integration, utilities customer linkage and backfill — separate final work.

See [phases](docs/PHASES.md) and [verification status](docs/BUILD_STATUS.md). Do not deploy the local Supabase Auth configuration to the shared project; its other apps may require public signup.
