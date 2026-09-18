# ComfyUI ACE-Step 1.5 XL

Music generation with ACE-Step 1.5 XL on ComfyUI. Deploy it from the Runpod Hub
as a Serverless endpoint to run workflows through the queue API, or as a Pod to
exercise that same worker with readable logs. Both take the same job shapes;
ComfyUI runs inside either one, with the job handler alongside it.

**A Hub deploy never gives you the ComfyUI web UI.** A Hub listing cannot
declare its own ports, so only port 80 is reachable and ComfyUI's 8188 is not.
To use ComfyUI in a browser, run the GHCR image from a Runpod template
instead — see [In a browser](#in-a-browser).

Models are not baked into the image. They are downloaded from Hugging Face on
first boot, so the first start takes a while. `ACESTEP_XL_VARIANT` decides which
diffusion model comes down, and it defaults to `xl_turbo`; the deploy screen's
presets set it for you. Note that picking Turbo over Base does not shorten that
wait — each XL model is 9.28 GiB, so only the `all` preset takes longer. Turbo
is faster to sample from, not faster to fetch.

The text encoders are not part of that choice: qwen_0.6b and qwen_4b are always
downloaded together, because every official ACE-Step 1.5 XL workflow loads the
pair.

## Deployment

| Method | Use case | Billing |
|---|---|---|
| Serverless endpoint | Serve generation. Start here. | Per second, only while a worker runs |
| Pod | Exercise the worker and read its logs | Per hour, whether or not jobs arrive |

Both run the same worker and take the same job shapes. Neither exposes the
ComfyUI web UI.

### On a Serverless endpoint

`https://api.runpod.ai/v2/ENDPOINT_ID/run`, with an `Authorization: Bearer`
header carrying a Runpod API key. Poll `/status/JOB_ID` until it reports
`COMPLETED` — the first job of a cold worker waits through the model download,
which is longer than `/runsync` will hold a connection open.

### On a Pod

`https://POD_ID-80.proxy.runpod.net/v2/LOCAL/runsync`. The startup log prints
this as `Local API is ready`. There is no page at `/`, so a 404 there is
expected rather than a fault.

⚠️ **This endpoint takes no authentication.** Anyone who knows the pod id can
submit workflows to it. That does not raise the bill — a pod is billed by the
hour either way — but it does hand out your GPU and lets a stranger run
arbitrary ComfyUI graphs on it. Do not paste the proxy URL anywhere public.

### In a browser

Not through the Hub. The image is published to GHCR as well, so create a Runpod
template from
`ghcr.io/ryoheitanaka/runpod-templates-acestep15xl:latest-cuda12.8`, declare
`8188/http` in its ports, and open **Connect to HTTP Service [Port 8188]** on
the resulting pod.

### The API

Two request shapes, both real:

```jsonc
// No workflow: returns ComfyUI's /system_stats. A liveness and capability
// check that costs nothing.
{ "input": { "health_check": true } }

// A workflow in ComfyUI's API format: runs it and returns the outputs.
{ "input": { "workflow": { /* ... */ } } }
```

Any input without a `workflow` key takes the first path, so the probe key
itself does not matter. It does have to be non-empty, though: Runpod drops an
empty `input` from the job it hands the worker, and the SDK then rejects the
job with `Job has missing field(s): id or input.` before the handler runs.

Outputs come back base64-encoded under `files`, each with its `filename`,
`kind` (`audio` for ACE-Step) and originating `node_id`. Anything larger than
`COMFY_MAX_INLINE_BYTES` is reported by name and size rather than inlined.

Export a workflow from the ComfyUI UI with **Workflow → Export (API)** to get
the format this expects — the UI's normal save format will not work.

### First boot

Models are downloaded rather than baked in, so the first boot pulls the image
and then the weights. Measured 2026-09-18 on a Hub pod deploy (NVIDIA L4,
EU-RO-1) with the Base preset, so one diffusion model plus both encoders,
18.5 GiB:

| | |
|---|---|
| image pull and unpack | 50s |
| model download (18.5 GiB) | 1m50s |
| ComfyUI startup | 10s |
| **total** | **2m52s** |

The pull is quick here because a Hub deploy pulls from registry.runpod.net.
Pulling the GHCR copy from outside Runpod is slower — an earlier run on an
RTX 4090 spent 4m27s on the pull alone.

The weights are not baked into the image on purpose: doing so would move those
gigabytes into the pull, which is the half you cannot cache between pods.

On a Pod this is a one-time wait. On a Serverless endpoint it is a cold start
every time a worker starts from zero, so keep an active worker rather than
scaling to zero if that matters to you. The handler waits for ComfyUI before
answering, so a job submitted during startup is served once it is up rather
than failing.

## Environment variables

| Name | Default | Description |
|---|---|---|
| `ACESTEP_XL_VARIANT` | `xl_turbo` | Diffusion model to download. One of `xl_base`, `xl_sft`, `xl_turbo`, `all`. |
| `HF_TOKEN` | unset | Optional. Set a real token to avoid anonymous rate limits while downloading. |
| `COMFY_PINNED_MEMORY` | `auto` | `auto` reads the container memory limit from cgroup and disables pinned memory when that limit is well below host RAM. Override with `on` or `off`. |
| `COMFY_EXTRA_ARGS` | unset | Extra arguments passed straight to ComfyUI, for example `--lowvram`, `--cache-none`, `--reserve-vram 2`. |
| `COMFY_PORT` | `8188` | Port ComfyUI listens on. Pinned so it stays put no matter what `PORT` the platform sets. |
| `COMFY_MAX_INLINE_BYTES` | `50331648` | Largest output returned inline as base64. Bigger files come back by name only. |
| `COMFY_WORKFLOW_TIMEOUT` | `1800` | Seconds a single workflow may run before the job gives up. |
| `WORKSPACE` | `/workspace` | Base directory for ComfyUI, models, cache, and logs. |

Both `qwen_0.6b` and `qwen_4b` text encoders are always downloaded. The official
ACE-Step 1.5 XL workflows load both through `DualCLIPLoader`, so there is nothing
to choose here.

An unsupported `ACESTEP_XL_VARIANT` makes the start script exit with an explicit
error rather than falling back to a default. `ACESTEP_LM` is no longer used:
passing it is ignored with a warning rather than treated as an error.

## Recommended GPU

20 GB of VRAM or more (RTX 3090, RTX 4090, A5000, or better).

## If the container dies without a traceback

Loading several large models in a row can restart the whole container with no
Python traceback. **This is about host RAM, not VRAM.**

ComfyUI and `comfy-aimdo` read the host's RAM rather than the limit the container
was actually given. On a large host where the container's share is small, they
size pinned memory against host RAM, so loading a second model crosses the
container limit and the container is OOM-killed.

The start script reads the real limit from cgroup and adds
`--disable-pinned-memory` when it is well below host RAM. The boot log shows:

```text
[start] memory: container limit 32GB / host 252GB
[start] container limit is well below host RAM, disabling pinned memory
```

If it still dies, pass `--lowvram` or `--cache-none` via `COMFY_EXTRA_ARGS`.

## Health check

Nothing needs configuring. The handler waits for ComfyUI to answer before it
processes a job, so a worker that is still downloading models holds the request
rather than failing it.

`healthcheck.py` ships in the image for the case where you want an HTTP health
endpoint of your own — it reports 204 while models download and 200 once
ComfyUI answers. Set `PORT_HEALTH` to a spare port to run it. It stays off by
default, and refuses to start on the same port as ComfyUI.

## Hub tests

`.runpod/tests.json` runs two tests. The first asks for `system_stats` and only
proves ComfyUI is up. The second submits the official
`ACE-Step 1.5XL Turbo: Text to Music` workflow in API format and requires it to
produce audio, which is what catches a broken model set — a missing text
encoder fails at `DualCLIPLoader`, and a health check never gets that far.

The test workflow is the official graph with two values lowered so the test
stays inside its timeout: `duration` / `seconds` are 10 seconds instead of 120,
and the tags and lyrics are short. Everything that decides whether the model set
is valid — both encoders, the diffusion model, the VAE — is unchanged. JSON
takes no comments, which is why this note lives here.

## Paths

| Path | Purpose |
|---|---|
| `/opt/ComfyUI` | ComfyUI checkout |
| `/workspace/models/acestep15xl/comfy-files` | Downloaded model files |
| `/opt/ComfyUI/models/*` | Symlinks to the downloaded models |
| `/workspace/outputs` | Generated output |
| `/workspace/logs` | Boot logs |

## License

The template code in this repository is MIT licensed. ACE-Step 1.5 XL and
ComfyUI carry their own licenses — check them at their respective sources.
