# Versioned offline usage estimates

The UI adapts the original Syrtis cost fields from normalized collector rows.
The collector never contacts a pricing endpoint. The bundled catalog is
`offline-ui/Sources/UsageCore/Resources/prices-v1.json`; each exact model entry
carries its official source URL. Version `2026-10-29.standard-v1` contains 29
reviewed model rates, in USD per million tokens.

This is current-directory repricing of known tokens, not historical actual
spend, a subscription bill or provider-specific reseller pricing. The baseline
is standard short-context inference, five-minute cache writes and peak-period
prices where applicable. Long-context premiums, fast/batch/flex modes, region,
residency, tool charges, tax and negotiated/subscription discounts are not
reconstructed from daily aggregate rows. DeepSeek's retired model IDs are not
silently mapped to their replacements. Unknown model labels stay unpriced.

Rates were verified against official model pages and the following price pages:

- [OpenAI pricing](https://developers.openai.com/api/docs/pricing), with individual model-page URLs retained in the catalog.
- [Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing).
- [DeepSeek pricing](https://api-docs.deepseek.com/quick_start/pricing/).
- [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing), paid tier.
  Gemini 3.6/3.8 Flash use the list price valid through 2026-12-31 and Gemini 4
  Argon the list price valid through 2026-11-30; both double afterwards, so the
  catalog must be revised then. Gemini has no separate cache-write price, so
  `cache_write` is null. The agy label `gemini-4-argon-trial` is not listed
  separately and is deliberately priced at `gemini-4-argon` list rates; it is an
  estimate, not an agy subscription charge. `gemini-3.8-flash-n` has no official
  price and stays unpriced.

`PriceCatalog` validates schema, currency, version, labels and decimal rates,
then multiplies the five mutually exclusive buckets once. Reasoning uses the
output rate. Missing rates are acceptable only for a zero-sized bucket; a
nonzero unpriced cache-write bucket leaves the whole row unpriced. Decimal
arithmetic precedes conversion to the original Syrtis presentation DTO.

The UI prefixes monetary displays with an estimate marker, shows the catalog
version and priced-token percentage for the selected machine/Agent/year, and
excludes unpriced rows from the amount. The percentage measures token coverage,
not percentage of a hypothetical full bill. Daily/monthly/model cost views use
the same row-level calculation after filtering. Unknown amounts must not appear
as measured zero. The original DTO's internal zero placeholder is accompanied
by the explicit coverage note and per-model unavailable display.

Message fields count metered assistant responses/API calls, not all conversation
messages, user turns, tool calls or JSONL lines. They are deduplicated by each
adapter's existing identity rules. Count completeness is independent from token
coverage and price coverage. Hermes uses an optional explicit api_call_count;
legacy cumulative Codex records and unattributable residuals remain unknown.

Run `make fleet-ui-check` for original-target projection checks and
`make offline-integration COLLECTOR_BINARY=ABSOLUTE_BINARY` for core pricing,
counting and collector checks. `Syrtis --fleet-report-check PRIVATE_REPORT`
validates an actual fleet envelope through the shipping projection without
printing machine IDs, usage amounts or source paths. Keep private reports and
host deployment evidence outside Git.
