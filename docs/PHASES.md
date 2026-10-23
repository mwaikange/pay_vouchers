# Delivery phases

| Phase | Implementation | Verification / remaining work |
| --- | --- | --- |
| 1. Staff, suppliers, catalogue, customers | Built; existing admin_users access and foundation applied | Browser login/image upload still need review |
| 2. Sales records and settlement | Tables, payment records, fixed batches, daily preparation, two-email confirmation, discrepancy hold/resolution implemented | Rollback-only integration tests passed; real supplier email delivery pilot outstanding |
| 3. Supplier redemption | Scoped credentials, limits, ID/dual OTP, atomic redemption, immutable receipt and58/80 mm templates implemented; Edge Function deployed | API unit tests and live invalid-token request passed; real recipient SMS/email and printer pilot outstanding |
| 4. Reporting and pilot | Full-database financial summary and supplier town/store planning; loaded sales and receipt lists; rollback-only pilot script | Parallel stress test and visual/browser/printer verification remain |
| 5. Vendor app | Separate next step after portal review | No Vendor app, wallet or utilities changes made |

Local staff review: http://127.0.0.1:4173 when the preview server is running. Supplier emails need a public HTTPS portal deployment. Source is in https://github.com/mwaikange/pay_vouchers.

The final integration must inspect the existing wallet ledger and use one database transaction for debit, commission posting, sale/voucher registration and retry protection. Collect recipient name, normalized mobile, email, ID and town plus planned branch. Phone matching creates a provisional voucher-customer association; it does not verify identity or grant marketing consent. Customers in this portal belong to the PaySME voucher programme only. Do not import or display electricity, water, airtime or other third-party VAS purchase history here.

Current batch identifiers are PV-BATCH-number, shown alongside supplier name. Voucher codes use PAD plus96 random bits; confirmation and supplier credentials use256 random bits.

Customer and company views: voucher buyers have searchable, paginated individual records with voucher histories across suppliers. Sales, Settlements and Reports share an All companies / individual company selector. Server-side supplier filtering happens before list limits, and report totals cover the entire selected company's records.

