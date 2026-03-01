# Scout Context

## Entry Points

- billing/src/invoice.ts:142 — calculateTotal() throws when amount is NaN
- api/routes/invoice.ts:38 — POST /invoices handler, this is where the request enters

## Boundaries

Explore within:

- packages/billing
- packages/shared (only modules imported by billing)
- packages/api (only the route handler and its immediate middleware)

Do NOT explore:

- packages/frontend
- packages/analytics
- Any test files
- node_modules

## Max Depth

15 hops from any entry point.

## Notes

- Heavy DI usage via tsyringe throughout billing package
- Config-driven validation pipeline in packages/shared/src/validation/
- Custom EventBus with string-based dispatch in packages/shared/src/events/
