# The Ruby benchmark harness as an image: this gem's extension compiled from the repository, with Node 24 for the V8
# rows and Python 3 for the results writer, and tools/bench/run.sh as the entry point. Built from the repository's
# root:
#
#   docker build -t corvus-regex-ecma262-ruby .
#   docker run --rm -v <workloads.json>:/workloads.json:ro -v <texts dir>:/texts:ro -v <out dir>:/out <image>
#
# which writes /out/industry.json, the run's data file in the results page's shape. The ECMA-262 test data is cloned
# at depth 1 inside the container unless its data/ directory is mounted at /data. JOB=short, SECONDS_EACH, PASSES,
# CORES, SETTLE and RUN_URL pass through (see tools/bench/run.sh). The central benchmark site runs this image each
# night; .github/workflows/harness-image.yml builds, smoke-runs and publishes it.
FROM node:24.11.0-bookworm-slim AS node

FROM ruby:3.4-bookworm AS extension
RUN apt-get update && apt-get install -y --no-install-recommends libclang-dev clang && rm -rf /var/lib/apt/lists/* \
    && curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none
ENV PATH=/root/.cargo/bin:$PATH
WORKDIR /src
COPY . .
RUN rustup toolchain install 1.98.0 --profile minimal && rustup default 1.98.0 && bundle install --quiet && bundle exec rake compile

FROM ruby:3.4-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends git util-linux ca-certificates python3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local/bin/node /usr/local/bin/node
WORKDIR /harness
COPY --from=extension /src/lib lib
COPY tools tools
ENV RUBYLIB=/harness/lib
# The commit the image is built from, for the run's record (the image has no .git).
ARG COMMIT=""
ENV CORVUS_COMMIT=$COMMIT
ENTRYPOINT ["/harness/tools/bench/container-entry.sh"]
