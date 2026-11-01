# Generated — do not edit by hand

Produced by `tools/td-codegen` (forked tl2swift) from `tools/td-codegen/td_api.tl`
(TDLib 1.8.64-49b3bcbb) tree-shaken to `tools/td-codegen/seed.txt`.

Regenerate after changing the seed or bumping TDLib:

    cd tools/td-codegen
    swift run tl2swift td_api.tl ../../Packages/TDShim/Sources/TDShim/Generated 1.8.64-49b3bcbb 49b3bcbb seed.txt

When the app calls a NEW TDLib function or handles a NEW update, add it to `seed.txt`
([functions] / [updates]) and regenerate.

The package pins TDLibFramework 1.8.64-e0943d06, a later build of the same schema (its
`td_api.tl` is identical to 49b3bcbb's). Before pinning a newer TDLib, diff its `td_api.tl`
against the one these models came from: 1.8.65 and later remove or retype fields the models
decode as non-optional (`message.is_paid_ton_suggested_post`, `messageLocation`,
`draftMessage.input_message_text`, every `inputMessage*` file field), which fails decoding of
every message rather than one feature.
