FROM mcr.microsoft.com/dotnet/sdk:5.0-focal

ARG DEBIAN_FRONTEND=noninteractive
ARG JULIA_VERSION=1.11.6
ARG JULIA_MINOR=1.11
ARG ZIG_VERSION=0.15.2

ENV PATH="/root/.cargo/bin:/opt/vlang:/usr/local/bin:${PATH}" \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        curl \
        g++ \
        gcc \
        gfortran \
        ghc \
        git \
        gnupg \
        golang-go \
        ldc \
        libevent-dev \
        libgc-dev \
        libgmp-dev \
        libpcre3-dev \
        libssl-dev \
        libxml2-dev \
        libyaml-dev \
        make \
        nim \
        openjdk-11-jdk \
        php-cli \
        pkg-config \
        python3 \
        ruby-full \
        scala \
        tar \
        unzip \
        xz-utils \
        zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal && \
    rustup default stable

RUN npm install -g typescript ts-node @types/node

RUN curl -fsSL "https://julialang-s3.julialang.org/bin/linux/x64/${JULIA_MINOR}/julia-${JULIA_VERSION}-linux-x86_64.tar.gz" \
        | tar -xz -C /opt && \
    ln -s "/opt/julia-${JULIA_VERSION}/bin/julia" /usr/local/bin/julia

RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /opt && \
    ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

RUN git clone --depth 1 https://github.com/vlang/v /opt/vlang && \
    make -C /opt/vlang && \
    ln -s /opt/vlang/v /usr/local/bin/v

RUN curl -fsSL https://crystal-lang.org/install.sh | bash

WORKDIR /src
COPY . .

RUN dotnet build tools/Tools.csproj && \
    if [ -f crystal/shard.yml ]; then cd crystal && shards install --ignore-crystal-version; fi

ENTRYPOINT ["dotnet", "run", "--no-build", "--project", "tools/Tools.csproj", "--"]
CMD ["time-all", "--width", "500", "--height", "500", "--iterations", "2", "--format", "text", "--timeout", "120", "--skip", "swift"]
