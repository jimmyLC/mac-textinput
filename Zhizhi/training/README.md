# Spoken-style fine-tune (LoRA) for the local scorer

Self-written Taiwan-colloquial sentences in `data/` (no third-party text). `prepare.py` drops any sentence found in `eval/`, then writes `work/set/{train,valid}.jsonl`.

```
python3.11 -m venv ../.venv && ../.venv/bin/pip install mlx-lm
python3 prepare.py
../.venv/bin/python -m mlx_lm lora --model mlx-community/Qwen2.5-1.5B-4bit --train --data work/set --iters 400 --batch-size 4 --num-layers 16 --learning-rate 2e-5 --save-every 100 --adapter-path work/adapter
# pick the step with the lowest val loss (300), copy it to adapters.safetensors, then:
../.venv/bin/python -m mlx_lm fuse --model mlx-community/Qwen2.5-1.5B-4bit --adapter-path <dir> --save-path work/fused
# copy vocab.json merges.txt added_tokens.json special_tokens_map.json from the base model folder, then
.build/release/zhizhi-eval <repo> ai <zhizhi-ai> <fused folder>
```

Results on the 406-sentence set (engine + helper): base 1.5B tau 2.5 = 371 (91%), 14 chars broken; 900 sentences/200 steps = 382, 7 broken; 1230 sentences/300 steps = 384 (94%), 6 broken. Training and eval sentences are both self-written, so real typing will gain less. Not yet shipped in the app.
