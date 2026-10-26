# PaySME Vouchers

Standalone staff portal for suppliers, branches, products/pictures, voucher sales, payment orders, discrepancy handling, supplier credentials and reports. Uses the existing PaySME Supabase database and existing staff logins.

## Run locally

Node.js 22 or newer; no package installation is needed.

~~~sh
npm run dev
~~~

Open http://127.0.0.1:4173 in Chrome. Sign in with an existing active PaySME staff Auth account. Active completed super_admin staff have full access; other staff require explicit permissions.vouchers.read, write or manage_suppliers booleans. The portal has a separate Auth session storage key.

The browser uses the official Supabase client pinned to 2.104.0. Public project configuration is in config.js; optional overrides use .env.local and the names in .env.example. Backend/service keys are rejected by the build and server. The local server exposes only portal assets.

~~~sh
npm test
npm run build
npm run preview
~~~

The static build is in dist/. Supplier confirmation emails require a shareable HTTPS deployment; localhost is suitable for staff review but is not reachable by supplier email recipients. The repository includes vercel.json with dist as the output directory.

## Live backend

Project: zvoqrqdnuupdefsuiurt. Voucher foundation, existing-staff access, lifecycle tables, transactional operations, reporting and daily batching are applied. The paysme-vouchers Edge Function is deployed. Do not rerun creation scripts against this existing installation.

The daily job prepares payment orders at 00:05 Namibia time for unbatched paid vouchers through the previous local day. It does not transfer money. Staff record bank payments; finance receives a link, the supervisor receives an approval code, and successful supplier confirmation releases exactly the vouchers in the batch. Discrepancies hold the batch pending resolution and fresh supplier confirmation.

Suppliers use scoped server credentials for verification, physical-ID validation, recipient SMS+email OTP, atomic redemption and immutable receipts/reprints. No supplier portal account is needed. Product bundles and store credit have distinct entitlements. All support points to PaySME.

## Pricing

Supplier500 + PaySME markup20 = customer520. A store reference600 gives an80 saving. Money uses integer cents. Immediate rebates reduce settlement due; later rebates and vendor commission remain separate. Supplier funding consumption is tracked per exact batch membership.

## Integration boundary

The Vendor app purchase integration is maintained in `mwaikange/paysme_vendor_app`. It atomically debits the existing Utilities wallet, creates the sale/voucher, and links its Utilities history using one retry reference. No additional vendor commission is paid because the vendor already benefits from the account top-up discount. Both interfaces use active names from `namibian_towns` for town selection. Staff and supplier Edge routes still cannot fabricate paid sales. Historical utility backfill and promotional audiences remain separate. See [Vendor integration](docs/VENDOR_INTEGRATION.md).

## Customer and company views

Customers opens a voucher-only directory with individual customer contact records and paginated voucher purchase histories across suppliers. Sales, Settlements and Reports have an All companies / individual company selector. Company filters apply in the database before list limits, and reports aggregate the full selected dataset. Historical inactive suppliers remain selectable.

## References

- [Operational workflow](docs/OPERATIONS.md)
- [Supplier API](docs/SUPPLIER_API.md)
- [Delivery phases](docs/PHASES.md)
- [Verification status](docs/BUILD_STATUS.md)
- [SQL scripts](sql/README.md)

