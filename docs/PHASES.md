# Delivery phases

| Phase | Implementation | Verification / remaining work |
| --- | --- | --- |
| 1. Staff, suppliers, catalogue, customers | Built; existing admin_users access and foundation applied | Browser login/image upload still need review |
| 2. Sales records and settlement | Tables, payment records, fixed batches, daily preparation, two-email confirmation, discrepancy hold/resolution implemented | Rollback-only integration tests passed; real supplier email delivery pilot outstanding |
| 3. Supplier redemption | Scoped credentials, limits, ID/dual OTP, atomic redemption, immutable receipt and58/80 mm templates implemented; Edge Function deployed | API unit tests and live invalid-token request passed; real recipient SMS/email and printer pilot outstanding |
| 4. Reporting and pilot | Full-database financial summary and supplier town/store planning; loaded sales and receipt lists; rollback-only pilot script | Parallel stress test and visual/browser/printer verification remain |
| 5. Vendor app | Supplier/product purchase flow, atomic Utilities debit, zero extra commission, shared town dropdowns and receipt recovery implemented | Backend deployed; app/portal interface release and physical-device review remain. See [integration notes](VENDOR_INTEGRATION.md) |

Local staff review: http://127.0.0.1:4173 when the preview server is running. Supplier emails need a public HTTPS portal deployment. Source is in https://github.com/mwaikange/pay_vouchers.

The Vendor integration uses one database transaction for the Utilities debit, sale/voucher registration, history linkage and retry protection. No extra commission is posted: the vendor already benefits from its account top-up discount. Collect recipient name, normalized mobile, email, ID and a selected town; a planned branch is optional. Phone matching creates a provisional customer association; it does not verify identity or grant marketing consent.

Customer views remain exclusive to PaySME vouchers; third-party VAS history is outside this programme.

Current batch identifiers are PV-BATCH-number, shown alongside supplier name. Voucher codes use PAD plus96 random bits; confirmation and supplier credentials use256 random bits.

Customer and company views: voucher buyers have searchable, paginated individual records with voucher histories across suppliers. Sales, Settlements and Reports share an All companies / individual company selector. Server-side supplier filtering happens before list limits, and report totals cover the entire selected company's records.

