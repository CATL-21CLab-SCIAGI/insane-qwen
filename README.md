# insane-qwen

![insane-qwen: same weights, one neuron, a different voice](docs/trailer.svg)

A compact, private playground for **Qwen3.5-4B activation steering**. Compare original and steered responses in a browser or the included Embryo iOS client. The default is **layer 20, neuron 8888, additive intensity +0.6**, using the fixed four-context calibration from our discovery experiment. All indices are zero-based. Model weights stay unchanged.

![Live browser comparison with the neuron handle exposed](docs/demo.jpg)

## What ships

- **Web comparison:** independent conversations, streaming output, cancellation, model selection, examples, and original-versus-steered responses.
- **Neuron handle:** layer, neuron, add/multiply, intensity, and fixed/per-prompt calibration. Lyra's two-neuron recipe and its reverse remain presets. Changing a recipe starts a fresh steered conversation.
- **Sandbox agents:** the existing bash tool loop, workspace allowlist, bounded execution, live tool observations and saved run history. Connect an existing hardened sandbox pool; this package does not run model-written commands on the host.
- **iOS client:** comparison, chat, trajectories, history/search, labels, notes and JSON export, with tokenless Tailscale access. The web exposes custom handles; iOS uses the server default. Signing stays local.
- **Offline scanner:** one command scans neuron poles, compares random-direction controls and freezes a ranked shortlist. It is separate from the server and has no HTTP endpoint.

## Run privately

Use Python 3.11+ and an NVIDIA GPU with a compatible PyTorch/CUDA runtime. The verified environment used Python 3.11+, PyTorch 2.13.0, Transformers 5.17.0, aiohttp 3.14.5, and FLA 0.6.0. Install compatible GPU packages for your machine before installing this project; model weights are not included.

```sh
pip install -e '.[gpu,fla]'
# Only needed for sandbox agents: Qwen tool-call parsing uses vLLM's parser.
pip install -e '.[agent]'

insane-qwen-serve --model /path/to/Qwen3.5-4B \
  --host GPU_PRIVATE_IP --port 8004 \
  --secrets /private/backend-secrets.json --fla
```

The secrets file contains a `backend_api_key`, generated and stored by the deployment operator outside the checkout. The inference server requires it on every request. **The browser and iPhone do not receive or store this key.** vLLM is used only for optional tool-call parsing, not inference acceleration. Omitting `--fla` uses Transformers reference linear-attention kernels.

On the gateway host:

```sh
pip install -e .
mkdir -p state
cp config/gateway.example.json state/gateway.json
# Edit gateway.json: private backend addresses, Tailscale owner, origins,
# and the server-side secrets path. Add existing sandbox pools/images if needed.
INSANE_QWEN_STATE="$PWD/state" insane-qwen-web
# Expose localhost:18090 through Tailscale Serve, on your private tailnet only.
tailscale serve --bg --http=8090 http://127.0.0.1:18090
```

The gateway binds only to localhost and accepts the configured identity supplied by Tailscale Serve. Configure the exact browser origin in `gateway.json`; never expose this listener directly, and do not enable Funnel. Existing bearer clients remain supported when a `gateway_token` is configured server-side. Runtime configuration, credentials, conversations, downloaded models and scan outputs are ignored by Git.

`backends` maps model IDs to private URLs. `sandbox_pools` lists directories containing pool descriptors (`{"url":"http://private-pool:port"}`). `images` maps names to `{image, cwd, note, repo?, env?}`. Pool APIs must implement `POST /sandboxes`, `POST /sandboxes/{id}/exec`, and `DELETE /sandboxes/{id}` with isolation, no network, execution limits and cleanup. Empty pools/images preserve chat-only operation. The gateway retains `/harness`, `/images`, `/sandboxes`, `/agent/runs`, `/v1/models` and `/v1/chat/completions`.

## The handle

Pass this extra field to `POST /v1/chat/completions` or `POST /agent/runs` with model `qwen35-4b-steered`:

```json
{"steering":{"layer":20,"neuron":8888,"operation":"add","intensity":0.6,"calibration":"fixed"}}
```

Omitting it selects that default. An array of up to eight distinct positions composes interventions. The native model applies none. Requests are serialized through one shared model, and hooks are removed before the next request, including cancellation and errors.

For neuron activation `a`, down-projection column `w`, and residual norm `R`:

- **Add:** `a ← a + intensity × R / ||w||`. Zero is neutral.
- **Multiply:** `a ← intensity × a`. One is neutral; zero ablates; negative values flip the activation.

Fixed calibration uses the bundled residual medians across four contexts, including every real token. These constants belong to this Qwen3.5-4B checkpoint and tokenizer. Use `--calibration path/to/calibration.json` for another qualified calibration. Prompt calibration performs an unsteered forward on the current input, excludes token zero, and holds the resulting offsets fixed throughout generation. Multiplication does not need residual calibration.

Lyra's preset is L14 N8949 +1 and L13 N7956 −1 with prompt calibration. The reverse preset flips both signs; its label makes no claim about an “angel” persona. Intensity bounds are ±4 for addition and ±512 for multiplication; large values can collapse language into repetition.

## Discovery, sealed behind a command

```sh
insane-qwen-scan --model /path/to/Qwen3.5-4B \
  --output results/scan-001 --batch 192 --dose 0.8 --controls 64 --fla
# For kernel/batching qualification only, add --qualify-only.
```

The output directory must be new. The command records its contract/calibration, runs batching and restoration checks, scans 32 × 9,216 neurons in both directions, and writes per-layer NPZ files plus `frozen-candidates.json`. Ranking uses a fixed hostility-minus-kindness next-token score, excludes layers 0–2 and KL > 3, and selects four distinct neurons. Random-direction percentiles are descriptive, not multiple-testing-corrected significance. Read the shortlist, then validate candidates on held-out generations before choosing a web handle. The scanner never edits the serving default or deployment.

The package deliberately excludes old experiment launchers, copied upstream repositories, downloaded libraries, raw conversation archives and plotting environments. `_scan.py` and `_rank.py` are private implementation modules; `insane-qwen-scan` is their supported entry point. Serving does not import them.

## What the experiment found

![Measured hostility and repetition across additive and multiplicative intensity](docs/intensity-response.png)

On eight benign prompts with greedy decoding and a 128-token cap, **L20 N8888 +0.6 produced 4/8 clearly hostile responses and 0/8 repetition ratings**. At +0.8, hostility stayed 4/8 while repetition rose to 6/8; at +1, repetition was 8/8. Multiplication ×2, ×8 and ×32 produced neither clear hostility nor repetition in this sample; ×512 produced repetition in all eight.

These are small-sample, single-judge observations. A fresh release smoke prompt about finishing a difficult project already produced repetition at +0.6, confirming that the eight-prompt result does not generalize to every input. The +0.6 outputs reached the token cap; zero repetition in those prefixes does not establish coherence in longer responses. Negative word associations alone do not establish hostility, and an imposed activation is not evidence of a naturally necessary or uniquely “evil” neuron. The chart combines the original validation with a 104-response intensity follow-up. It is historical experiment evidence, not a fresh benchmark of this package.

## iPhone

```sh
cd ios
python3 scripts/generate-project.py
open Embryo.xcodeproj
swift test
scripts/build.sh simulator
```

Select your own development team in Xcode, or set `DEVELOPMENT_TEAM` when generating. The existing client is configured for `dsw-evergreen.tail1c6dfa.ts.net:8090`; for another deployment update `EmbryoEndpoint.swift`, its endpoint tests, the app's endpoint default and the ATS domain in `Info.plist`. Use the included device-install script with a trusted unlocked device. This repository includes no signing profiles or private keys. Stop cancels the connection; agent completion remains visible in server history.

## Verification and layout

```sh
python -m unittest discover -s tests -v
node --check src/insane_qwen/web/app.js
```

`src/insane_qwen/` contains the shared steering contract, inference server, private gateway, static web app and encapsulated scanner. `ios/` is the native client. `tests/` covers invalid handles, additive/multiplicative behavior, calibration, exception cleanup, HTTP framing, authentication and cancellation isolation. See [verification](docs/verification.md) for the actual checks performed for this release.

## Acknowledgements and references

- **Lyra** originated the Qwen neuron recipes and published [neuron-explorer](https://github.com/lyramakesmusic/neuron-explorer). Our search follows the causal steer-lens approach at commit [`ddb144e`](https://github.com/lyramakesmusic/neuron-explorer/tree/ddb144e4121fbeb16ec080077dd67247e499132d), extended with a fixed lexical ranking, random controls and held-out validation. Original posts: [two-neuron recipe](https://x.com/_lyraaaa_/status/2113833330429083662) and [additional characters](https://x.com/_lyraaaa_/status/2113887372610077136).
- **Zucan** prompted the [single-neuron ablation](https://x.com/zucan_lv/status/2114436784201359552); **vashinthewild** reported the [reverse-direction observation](https://x.com/vashinthewild/status/2114511531920802011). These motivated tests, rather than establishing our results.
- [**Persona Vectors: Monitoring and Controlling Character Traits in Language Models**](https://arxiv.org/abs/2507.21509) provides related residual-direction methodology. Raw MLP-neuron search is a different procedure.
- [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B), [Transformers](https://github.com/huggingface/transformers), [PyTorch](https://pytorch.org/), [Flash Linear Attention](https://github.com/fla-org/flash-linear-attention), [vLLM](https://github.com/vllm-project/vllm) and [Tailscale](https://tailscale.com/) provide the model and runtime foundations.

Packaged by **EvergreenTree** for **CATL-21CLab-SCIAGI**. This is a private research repository. Third-party software and model weights retain their own licenses; no upstream weights or dependency source trees are bundled.
