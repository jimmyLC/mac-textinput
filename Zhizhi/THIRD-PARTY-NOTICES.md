# Third-party components in 知之

Used by the local-AI helper `zhizhi-ai`. The license texts of the two direct packages are copied into `Contents/Resources/licenses` at build time; the rest still need collecting before any public release.

| Component | License | Use |
|---|---|---|
| ml-explore/mlx-swift 0.33.0 | MIT | Runs the model on the GPU |
| huggingface/swift-transformers 1.4.0 | Apache-2.0 | Tokenizer, loaded from a local folder only |
| Their dependencies (swift-huggingface, swift-jinja, swift-collections, swift-crypto, swift-asn1, swift-numerics, EventSource, yyjson) | See each package in `AI/Package.resolved` | Pulled in by the above; not checked yet |
| Qwen2.5-1.5B, MLX 4-bit conversion (mlx-community) | Apache-2.0 according to the model page; not bundled, stays in Application Support | Scores homophone choices |

The lexicon's sources are listed in the repository README; its McBopomofo-derived data keeps the MIT notice.

## Chinese Wikipedia (word-pair statistics)

`chinese-pairs.bin` holds counts of adjacent word pairs taken from the Chinese Wikipedia
dump named in `data/chinese-bigram-stats.json`. Wikipedia text is licensed under
Creative Commons Attribution-ShareAlike 4.0 (https://creativecommons.org/licenses/by-sa/4.0/),
© Wikipedia contributors. The file contains statistics only, no article text.
