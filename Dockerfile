FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        xorriso \
        dpkg-dev \
        apt-rdepends \
        wget \
        gzip \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /localbooth

COPY . /localbooth/

RUN chmod +x build/*.sh packages/*.sh repo/*.sh iso/*.sh bootstrap/*.sh

ENTRYPOINT ["/localbooth/build/build-iso-in-docker.sh"]
