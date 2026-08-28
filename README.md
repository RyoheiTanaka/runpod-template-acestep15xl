# ComfyUI ACE-Step 1.5 XL

Music generation with ACE-Step 1.5 XL on ComfyUI. Deploy it from the Runpod Hub
as a Pod for the ComfyUI web UI, or as a load balancing endpoint to drive the
ComfyUI HTTP API directly.

Models are not baked into the image. They are downloaded from Hugging Face on
first boot, so the first start takes a while. The default preset is the smallest
combination (Turbo + Qwen 0.6B) to keep that first boot short.

## Deployment

| Method | Use case |
|---|---|
| Pod | Use the ComfyUI web UI in a browser. Start here. |
| Load balancing endpoint | Call the ComfyUI HTTP API directly, with autoscaling. |

On a Pod, open **Connect to HTTP Service [Port 8188]** to reach ComfyUI.

### First boot is slow, deliberately

Because models are downloaded rather than baked in, the first boot pulls a
~10GB image and then several GB of weights. Measured end to end with the
default preset, a container reaches a serving ComfyUI in about 7 minutes.

On a Pod that is a one-time wait. On a load balancing endpoint it is a cold
start every time a worker spins up from zero, which is why this listing sets
`RUNPOD_INIT_TIMEOUT=1800` — the platform otherwise marks a worker unhealthy
after 7 minutes. If you need fast cold starts, keep an active worker rather
than scaling to zero.

## Environment variables

| Name | Default | Description |
|---|---|---|
| `ACESTEP_XL_VARIANT` | `xl_turbo` | Diffusion model to download. One of `xl_base`, `xl_sft`, `xl_turbo`, `all`. |
| `ACESTEP_LM` | `qwen_0.6b` | Text encoder to download. One of `qwen_0.6b`, `qwen_1.7b`, `qwen_4b`, `all`. |
| `HF_TOKEN` | unset | Optional. Set a real token to avoid anonymous rate limits while downloading. |
| `COMFY_PINNED_MEMORY` | `auto` | `auto` reads the container memory limit from cgroup and disables pinned memory when that limit is well below host RAM. Override with `on` or `off`. |
| `COMFY_EXTRA_ARGS` | unset | Extra arguments passed straight to ComfyUI, for example `--lowvram`, `--cache-none`, `--reserve-vram 2`. |
| `PORT` | `8188` | Port ComfyUI listens on. `COMFY_PORT` works too. |
| `PORT_HEALTH` | `8189` | Port for the health check server. Only used by load balancing endpoints. |
| `WORKSPACE` | `/workspace` | Base directory for ComfyUI, models, cache, and logs. |

Unsupported values make the start script exit with an explicit error rather than
falling back to a default.

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

For load balancing endpoints, a small health check server listens on
`PORT_HEALTH`. It returns `204` (initializing) while models are still
downloading and ComfyUI is not up yet, and `200` once ComfyUI's `/system_stats`
responds.

This server is unused when deployed as a Pod.

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
