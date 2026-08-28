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

### First boot

Models are downloaded rather than baked in, so the first boot pulls the image
and then the weights. Measured on a Runpod pod with an RTX 4090 and the default
preset:

| | |
|---|---|
| image pull and unpack | 4m27s |
| model download | 25s |
| ComfyUI startup | 9s |
| **total** | **5m01s** |

The pull dominates; the model download is a small part of it, which is why the
weights are not baked into the image — doing that would add gigabytes to the
slow half to save part of the fast one.

On a Pod this is a one-time wait. On a load balancing endpoint it is a cold
start every time a worker starts from zero, so keep an active worker rather
than scaling to zero if that matters to you.

## Environment variables

| Name | Default | Description |
|---|---|---|
| `ACESTEP_XL_VARIANT` | `xl_turbo` | Diffusion model to download. One of `xl_base`, `xl_sft`, `xl_turbo`, `all`. |
| `ACESTEP_LM` | `qwen_0.6b` | Text encoder to download. One of `qwen_0.6b`, `qwen_1.7b`, `qwen_4b`, `all`. |
| `HF_TOKEN` | unset | Optional. Set a real token to avoid anonymous rate limits while downloading. |
| `COMFY_PINNED_MEMORY` | `auto` | `auto` reads the container memory limit from cgroup and disables pinned memory when that limit is well below host RAM. Override with `on` or `off`. |
| `COMFY_EXTRA_ARGS` | unset | Extra arguments passed straight to ComfyUI, for example `--lowvram`, `--cache-none`, `--reserve-vram 2`. |
| `PORT` | `8188` | Port ComfyUI listens on. `COMFY_PORT` works too. |
| `PORT_HEALTH` | unset | Set to a second port (e.g. `8189`) to run the bundled health check server there, reporting 204 while models download. Only reachable where you control port exposure. |
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

Load balancing endpoints poll `HEALTH_CHECK_PATH`, which points at ComfyUI's own
`/system_stats` on the main port. That returns 200 once ComfyUI is serving, and
nothing answers before then, so a worker counts as unhealthy while it is still
downloading models rather than reporting itself as starting up.

`healthcheck.py` ships in the image and can report that distinction — 204 while
models download, 200 once ComfyUI answers — by setting `PORT_HEALTH` to a
second port such as 8189. It is not used by default: a Hub listing has no way
to declare which ports are exposed, so only the main `PORT` is reachable there.
Use it where you control port exposure, such as a Pod.

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
