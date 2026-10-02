# Kist terminal setup candidate

Open Kist in your repository. On first launch its existing arrow-key model picker
appears. Choose a model, let setup complete, then work in the same terminal.
There is no model-tag step. Later launches reuse the saved selection; `kist --setup`
opens setup again.

Local choices show download size. Setup reuses an existing Ollama executable or
installs a checksum-pinned private copy, then downloads the selected model. No
API key is needed. Local selection disables paid-provider fallback across the
provider registry. Cloud choices ask for the provider's key and use its pricing.
Existing provider allowlists remain authoritative; setup never widens them.

## Try the candidate

macOS/Linux: unpack the matching bundle, run `python3 install_bundle.py`, and add
`~/.local/bin` to PATH. Then open any repo and run `kist`. Python 3.9+ is required;
Linux also needs libzstd for a fresh private Ollama installation. Linux's Swift
shared libraries are not yet bundled; a compatible Swift runtime must already be
available in Linux/WSL. This is a remaining release prerequisite.
The installer refuses to overwrite an existing Kist installation. Use `--prefix /another/path`
for an isolated trial. An unpacked bundle can also be run directly through its
`kist` launcher, without installing it.

Windows Terminal/PowerShell: use the **Linux bundle** with an existing WSL2
distribution and Python 3. Run `& 'C:\path\to\bundle\kist.ps1'` from your repo.
It preserves that repo's location, opens the same picker, and stores settings in
your WSL home. It does not install a distribution or substitute another Windows
release. Native Windows execution is not implemented.

Set `OLLAMA_MODELS` to an external model directory before opening Kist if desired.
The launcher otherwise reuses `~/.ollama/models` (including external symlinks),
or creates `~/.local/share/kist/models`. It refuses an absent macOS `/Volumes`
mount instead of downloading onto the internal disk. `KIST_DATA_HOME` can move
the private runtime and controller state too. Keep these settings in your shell
profile so later launches use the same locations.

## Model lifecycle

- `kist local-ai auto`: allow models to load when called.
- `kist local-ai off`: stop current managed inference and reject new local calls.
- `kist local-ai freeze` and `kist local-ai kill`: aliases for off.
- `kist local-ai status`: show mode and active controllers without loading a model.

Only one managed local worker may run across Kist sessions. Models unload after
requests; controllers stop when their terminal session exits. Memory pressure,
timeouts and disconnected clients stop workers. These controls affect this
packaged runtime, not Ollama processes owned by other applications.

The initial download choices are Qwen2.5-Coder 1.5B and 0.5B when they fit the host's
weight limit (one eighth of RAM, up to 8 GiB). Installed models within that limit
also appear. A small model's download readiness does not establish reliable
coding ability or parity with a cloud model. Local vision is currently disabled.
The selected download variants have Apache-2.0 model cards:
[1.5B](https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct) and
[0.5B](https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct).
The 3B variant is excluded from automatic downloads because its model card lists
[Qwen Research](https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct), a different license.

## Memory admission and single-Mac sharding

`kist --local-model-plan qwen2.5-coder:1.5b` reports the same memory decision used
before local chat and tool calls. It reads metadata only; it does not download,
load weights, start a cluster or spend API tokens. Exit 0 means the estimate fits;
exit 2 means fallback is needed or metadata is unavailable. A diagnostic decision
is temporary: inference takes another host snapshot before loading.

Kist counts the installed model's **total** size, estimates its K/V cache from
layer count, KV heads, attention dimensions and requested context, and reserves
workspace of at least 1 GiB or 20% of weights. Cache estimates use f16 even if the
backend requests quantized caching, so unsupported cache compression earns no
memory credit. One request may use at most half of physical RAM and must leave
at least 1 GiB of current available memory. Warning/critical or unknown pressure
blocks loading. macOS observations conservatively exclude anonymous inactive and
compressed pages, so the policy can choose fallback before all RAM is exhausted.
It is a protective estimate, not a guarantee of performance or peak allocation.

The initial estimator supports ordinary text attention in llama, qwen2, qwen3,
gemma, gemma2, gemma3, phi2 and phi3. Hybrid/recurrent/MLA, multimodal, missing or
malformed metadata fail closed until their allocation has a supported estimator.
Explicit context is never silently shortened. Small models retain the existing
picker, external storage and unload-after-request lifecycle. Allowed cloud
fallback can continue after a capacity failure without repeating local retries;
local-only settings and explicit route policies still apply.

This is a **single-host** policy. Apple Silicon CPU and GPU share RAM; disk and
swap are not extra inference capacity. GGUF file shards are storage pieces of
one model and their sizes must be counted together. Splitting a 70B model does
not make it fit a 16 GiB Mac. Kist does not automatically split weights, discover
peers, install Exo or claim a distributed backend exists. Multi-machine placement
requires a separately configured cluster and is not implemented in this layer.
Explicit remote Ollama endpoints retain their server's admission policy; this
Mac's RAM must not be applied to a remote machine.

Primary references: [Ollama memory/concurrency and unloading](https://docs.ollama.com/faq),
[Ollama model metadata](https://github.com/ollama/ollama/blob/main/docs/api.md),
[GGUF file splitting](https://github.com/ggml-org/llama.cpp/tree/master/tools/gguf-split),
[Apple Mach memory counters](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h),
and [Exo distributed inference](https://github.com/exo-explore/exo).

## Release status

This is a candidate packaging path. macOS, Linux and WSL need separate compatible
builds; one binary does not run on every OS/CPU. Checksums detect transfer damage,
not publisher identity. The repository still needs a public license decision,
release signing/distribution, green release gates and Linux/WSL execution checks
before this is advertised as a public download. No public release is published
by these scripts.

Maintainer: build `swift build -c release --product kist --jobs 2`, then run
`python3 Tools/kist_local_runtime/package.py --binary .build/release/kist --output /new/bundle/path`.
The package includes SwiftPM resource bundles, launcher, runtime and installer.
