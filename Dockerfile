# The heavy layers -- apt packages, the torch/torchvision pairing, the ComfyUI
# checkout, its requirements, and the runpod SDK -- are not built here. They
# live in a prebuilt public base image, built by RyoheiTanaka/runpod-templates
# from base/Dockerfile, which is where the reasoning behind each of them is
# recorded.
#
# They were moved out because of the Hub's build ceiling. A Hub `docker build`
# is killed at 30 minutes, separately from the 160-minute overall window. The
# v0.4.0 build hit it without a single line of this Dockerfile having changed:
# the builder's pip download ran at 68-80 kB/s and was cut off part way through
# a 100 MB wheel, while the same Dockerfile built in about 4 minutes on GitHub
# Actions. There is no retry button for a Hub build, so recovering meant
# re-releasing identical content under a new version number.
#
# Pre-building and pulling from a registry is what Runpod's own documentation
# recommends for this. With the work already done, what remains here is a few
# COPY lines, so a slow builder can no longer fail the build.
#
# The base image must stay public on GHCR -- the Hub cannot use a privately
# hosted image as a base.
#
# Bumping ComfyUI or any dependency means cutting a new base-v* tag in
# runpod-templates and raising this pin. It does not happen implicitly.
ARG BASE_IMAGE=ghcr.io/ryoheitanaka/runpod-comfyui-base:v1-cuda12.8
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/RyoheiTanaka/runpod-template-acestep15xl"

COPY start.sh /opt/runpod/start.sh
COPY handler.py /opt/runpod/handler.py
COPY healthcheck.py /opt/runpod/healthcheck.py
RUN chmod +x /opt/runpod/start.sh

WORKDIR /workspace
EXPOSE 8188 8189 22
CMD ["/opt/runpod/start.sh"]
