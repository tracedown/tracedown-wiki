FROM python:3.12-slim AS build

WORKDIR /app
COPY pygments-lace/ pygments-lace/
COPY mkdocs.yml .
COPY docs/ docs/
COPY overrides/ overrides/

# Social cards (the `social` plugin) rasterise the logo and page text, so the
# build stage needs Cairo, FreeType and friends. Package list is upstream's:
# https://squidfunk.github.io/mkdocs-material/plugins/requirements/image-processing/
RUN apt-get update && \
    apt-get install --no-install-recommends -y \
        libcairo2-dev \
        libfreetype6-dev \
        libffi-dev \
        libjpeg-dev \
        libpng-dev \
        libz-dev && \
    rm -rf /var/lib/apt/lists/*

# `mkdocs-material[imaging]` pulls cairosvg + pillow, required by the social plugin.
# The build needs outbound network: the social plugin fetches the card font from
# Google Fonts on first build.
RUN pip install --no-cache-dir "mkdocs>=1.6,<2" "mkdocs-material[imaging]>=9.6,<10" ./pygments-lace && \
    mkdocs build --strict

FROM nginx:alpine
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY --from=build /app/site /usr/share/nginx/html
