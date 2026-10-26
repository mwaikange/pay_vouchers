# Supplier redemption integration

Base URL: `https://zvoqrqdnuupdefsuiurt.supabase.co/functions/v1/paysme-vouchers`

All supplier calls are POST with JSON and the `x-voucher-api-key` header. PaySME staff issue the credential in Settlements. Credentials identify the supplier and optionally restrict the branch. Keep the credential on the supplier server; do not embed it in a browser, public app or source repository. Rotate by issuing a replacement, changing the supplier server, then revoking the old credential ID.

Every request includes `voucher_code` and `pos_staff_reference`. A supplier-wide credential also needs `branch_id`; a branch credential uses its assigned branch. Only active supplier branches are allowed. A default limit of 120 requests per minute applies to each credential. Verification failures have additional voucher/challenge limits.

| Endpoint suffix | Additional fields | Result |
| --- | --- | --- |
| `/verify` | None | Status, product contents, entitlement type, customer price and whether redeemable. No recipient ID, email or mobile is returned. |
| `/validate-id` | `id_number` | Short-lived `verification_id` after matching the ID presented at the store. Supplier must physically inspect the document. |
| `/request-otp` | None | Sends separate codes to the recipient's purchase-time mobile and email; returns `verification_id`. |
| `/validate-otp` | `verification_id`, `sms_otp`, `email_otp` | Requires both codes. On success, verification is usable for five minutes. |
| `/redeem` | `verification_id`, `request_key` (UUID) | Single redemption and immutable receipt. Reuse the same request key after a network failure. |
| `/receipt` | Optional `format: "html"`, `width: "58"` or `"80"` | The existing receipt, without another redemption. With HTML format, response includes `receipt` and escaped printable `html`. |

Example verification:

```http
POST /functions/v1/paysme-vouchers/verify
Content-Type: application/json
x-voucher-api-key: <supplier-server-secret>

{
  "voucher_code": "PAD-01234567-89ABCDEF-01234567",
  "branch_id": "<supplier-branch-uuid>",
  "pos_staff_reference": "STORE-01-CASHIER-04"
}
```

Example redemption after identity verification:

```json
{
  "voucher_code": "PAD-01234567-89ABCDEF-01234567",
  "branch_id": "<supplier-branch-uuid>",
  "pos_staff_reference": "STORE-01-CASHIER-04",
  "verification_id": "<server-issued-verification-uuid>",
  "request_key": "<new-uuid-persisted-for-this-redemption>"
}
```

The supplier cannot pass a boolean saying identity was checked. A server-issued verification belongs to the voucher, supplier, branch and POS staff reference. Physical-ID verification lasts five minutes; recipient codes expire after ten minutes and allow five incorrect attempts. Recipient-code requests have a 60-second cooldown and a maximum of five per voucher per hour. Physical-ID failures lock the voucher's ID check for 15 minutes after five failures.

Responses use 200 on success, 400 for invalid request structure, 401 for missing credentials, 403 for staff authorization failures, 409 for state/verification conflicts, 413 for oversized requests, and 503 for notification failures. A JSON `error` must never be treated as verification or redemption success. Supplier-rate errors currently use 409; retry after one minute. No raw provider errors or ID numbers are returned.

Supplier code should retain the request key until the final receipt arrives. A retry with the same key returns the original receipt. A different key cannot redeem an already redeemed voucher. If printing fails, use `/receipt`; do not start another redemption. Receipt lookup is supplier-scoped; PaySME staff can also inspect immutable receipt records for support.

The API supplies authoritative receipt fields. The supplier controls printer drivers, roll length, layout and its internal use of the printed slip. Optional 58/80 mm templates set content width; the printer's selected paper/roll settings determine page length. A product bundle is not automatically store credit. Store-credit value is returned only for a product configured as store credit. Customer payment and supplier settlement consumption are separate amounts.

All customer support goes to PaySME (`support@paysme.site`). Supplier credentials are unrelated to the two email contacts used for batch payment confirmation. No supplier staff portal account is needed.

The base endpoint also accepts `{ "action": "verify_voucher", "args": { ... } }` for existing clients. Dedicated supplier paths override any action supplied in the body. Staff and supplier actions are individually authenticated by the handler. Platform JWT verification is disabled because supplier keys and confirmation tokens are not Supabase user JWTs; this does not grant unauthenticated access to staff or supplier operations.


## Cash and prepaid funding

The same six endpoints support both supplier payment models. On prepaid terms, PaySME owns prepaid funds held with the supplier. PaySME checks its own available funds before emailing a batch review; the supplier reviews each batch and uses a supervisor OTP before vouchers become redeemable. Initial PaySME prepayments and top-ups have separate POP/amount approval. Suppliers can report a balance mismatch from the emailed link. There is no requirement to verify new bank details for a prepaid batch, create supplier portal accounts or build a separate approval system.

A voucher in an approved prepaid batch has already been charged against PaySME’s funds, even while unredeemed. Redemption consumes the voucher’s batch allocation once and never charges the prepaid balance again. Vendor sales remain funded by their own existing Utilities wallets, independently of PaySME’s funds with the supplier. When a batch releases vouchers, a buyer SMS is queued with the code and requested collection location. Requested branches in daily planning are customer intentions, separate from the actual redemption branch captured by this API.
