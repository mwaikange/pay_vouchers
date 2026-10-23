# Phase 1 verification status

Implemented:
- Staff login and active-membership gate, with a separate browser session storage key for the voucher portal.
- Supplier create/edit with distinct finance and supervisor emails; supplier writes restricted to admins.
- Branches with towns and addresses; product contents, pictures, rebate timing and pricing.
- Customer directory with masked mobile display. Utility linking, historical imports, identity checks and marketing remain deferred.
- SQL Editor scripts for creation, enrollment, read-only verification and a rollback-only permissions smoke test.
- Localhost static preview/build without package installation. Browser uses the official Supabase client from a pinned CDN URL.
- GitHub Actions run Node tests and a static build.

Local verification:
- Domain tests cover agreed pricing, money validation, distinct approval emails and Namibian mobile normalization.
- Additional tests cover path traversal/secret-file rejection and refusal to ship backend keys as browser configuration.
- JavaScript syntax and static build checked.
- The HTTP integration test is skipped only when this local runtime returns EACCES for localhost connections. It remains enabled in CI; other errors fail the test.

Pending external verification:
- SQL creation and the real RLS smoke test must run in Supabase. No live SQL has been applied from this work.
- Live Auth enrollment/login, Storage uploads and visual browser QA require the configured database and a working browser runtime.
- Sales, wallet debits, supplier confirmation and voucher redemption are later phases and cannot be used for real money yet.

The Vendor application and its business tables remain unchanged.
