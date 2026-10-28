# Release verification — 2026-10-28

Checks performed on the packaged source, not inferred from earlier experiments:

| Check | Result |
| --- | --- |
| Python regression suite | 8 tests passed: handle validation, additive/multiplicative effects, prompt calibration, cleanup on exceptions, backend authentication, stream framing, cancellation isolation, gateway identity/origin handling and handle forwarding |
| GPU serving smoke | Native → default steered → native completed; native responses matched exactly; default L20 N8888 offset was 23.8392562866 |
| Neutral interventions | Native, multiplication ×1 and additive zero produced identical choices through the live gateway; receipt in `smoke.json` |
| Browser comparison | Both models streamed and completed a real response with the default handle visible; `demo.jpg` captures that session |
| Sandbox-agent path | Steered model with neutral multiplication invoked bash, received output, finished, and saved history |
| Packaged scanner | `--qualify-only --batch 8 --fla` completed; baseline restored exactly; batch/single score max difference 0.0199523 and KL max difference 0.0150901 |
| iOS core | 25 tests passed in four suites |
| iOS build | Unsigned Simulator Debug build succeeded |
| Python distribution | Source archive and wheel built successfully; wheel contains all three entry points, calibration and static web assets |
| JavaScript | Syntax check passed; default controls and operation changes inspected in the live browser |

The screenshot uses a temporary localhost preview forwarded through the existing Tailscale HTTP proxy. Tailscale Serve authenticated the connection; no bearer token or fabricated identity header was supplied. The deployed app remains tailnet-only. This Mac's Tailscale was stopped, so its direct tailnet route was not verified in this release. The screenshot predates a small label/contrast refinement and the immediate numeric-input summary fix. Further browser interaction was declined; the final input-listener change has syntax validation, not a second browser run.

The initial GPU smoke exposed an outdated dictionary-based metadata formatter after interventions became a list. It was fixed before the successful checks above. A fresh greedy smoke prompt produced repetition at +0.6, while the sampled browser demo gave a short hostile answer. Neither observation is a broad behavior guarantee.

The scanner's exhaustive 589,824-pole search was not repeated for packaging. The README chart comes from the earlier eight-prompt validation and 104-response intensity study. No new performance, vLLM/SGLang inference, physical-iPhone installation, or long-context behavioral qualification is claimed.

## Retained features and removed material

The web and iOS app retain comparison, streaming, cancellation, history, sandbox agents and their existing client workflows. The gateway keeps the same API routes and external hardened pool contract. The web adds request-specific neuron controls; iOS follows the server default.

Excluded from the package: dated deployment/repair scripts, experimental result trees, copied upstream repositories, downloaded plotting/kernel libraries, generated build products, signing files and runtime configuration. Unused iOS token read/write paths were removed; deletion remains for migration of old installations. The scanner has one public command and two internal modules. Its batch intervention implementation remains separate from request-serving hooks because its per-row counterfactual layout differs.

No mathematical proof of globally minimal code is possible from these checks. The package contains no knowingly unused implementation path; generated Xcode configuration is retained so users can open the iOS project directly.
