# The factory worker gateway (ASP.NET Core minimal API that runs the PowerShell rule scripts and the sweep), one container.
# Build context = the root of the repository:  docker build -t fworker .
# The image holds gateway/, plugin/, config/ and prompts/ only; tests/, tools/ and docs/ are not copied (.dockerignore keeps them out of the context).
#
# What the demo-environment kit expects of a container deployable: this Dockerfile at the root; the port and health path
# system.json names for it (8080, /health); a non-root process; ARG VERSION for the build version (/_build answers it).
# The gateway shells out to `pwsh factory.ps1 --server <verb>`, so the runtime image carries PowerShell next to .NET.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY gateway/Gateway.csproj gateway/
RUN dotnet restore gateway/Gateway.csproj
COPY gateway/ gateway/
ARG VERSION=0.0.0
RUN dotnet publish gateway/Gateway.csproj --configuration Release --no-restore --output /app/publish \
    -p:UseAppHost=false -p:Version=${VERSION}

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
ARG PWSH_VERSION=7.5.4
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl libicu-dev \
    && curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz" -o /tmp/pwsh.tgz \
    && mkdir -p /opt/microsoft/powershell \
    && tar -xzf /tmp/pwsh.tgz -C /opt/microsoft/powershell \
    && chmod +x /opt/microsoft/powershell/pwsh \
    && ln -s /opt/microsoft/powershell/pwsh /usr/bin/pwsh \
    && rm -rf /tmp/pwsh.tgz /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/publish ./
COPY plugin/ /app/plugin/
# the gateway serves this directory to workers (GET /api/v1/plugin): the build fails when the skills or agents are missing from the image
RUN test -f /app/plugin/scripts/factory.ps1 && test -f /app/plugin/skills/factory-owner-session/SKILL.md && test -f /app/plugin/agents/factory-implementer.md && test -f /app/plugin/scripts/models.default.json && test -f /app/plugin/scripts/ensure-tools.ps1 && test -f /app/plugin/scripts/app-run.ps1 && test -f /app/plugin/scripts/app-shot.ps1 && test -f /app/plugin/tools/shot/Shot.csproj
COPY config/ /app/config/
# the prompts the gateway serves at /mcp (get_prompt, docs/design/agents-roles-launch.md 5)
COPY prompts/ /app/prompts/
RUN test -f /app/prompts/bootstrap/api.md && test -f /app/prompts/worker/development.md
# State (the sweep's seen/refusal caches) lives in the container's file system; the truth is on the board and in the
# item state comments, so a restart loses only caches and the plant's in-memory registry (workers re-register).
ENV ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_gcServer=0 \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=0 \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    FACTORY_PLUGIN_SCRIPTS=/app/plugin/scripts \
    FACTORY_CONFIG=/app/config/instance.json \
    FACTORY_STATE_DIR=/tmp/factory-state
# The deployed settings: config/deploy.overrides.json merged over config/instance.json (the source defaults, which the tests run on).
# The build fails on an override that names no existing setting, and when the merged file does not carry the deployed switches.
RUN pwsh -NoProfile -File /app/config/apply-overrides.ps1 -Base /app/config/instance.json -Overrides /app/config/deploy.overrides.json -Out /app/config/instance.json \
    && grep -q '"ownerSessions": true' /app/config/instance.json
EXPOSE 8080
USER $APP_UID
ENTRYPOINT ["dotnet", "FactoryWorker.Gateway.dll"]
