# syntax=docker/dockerfile:1
# FlashSale.ProcessWorker -- multi-stage image.
#
# Build context is the repository root (so the root .dockerignore applies and
# the ProjectReference to ../FlashSale.EventContracts resolves). The SDK image
# is pinned to 10.0.300 (matches global.json); the runtime is aspnet 10.0.8.
# The worker has no HTTP API; it serves only /metrics, still on plain
# HTTP inside the container (ASPNETCORE_URLS=http://+:8080).
FROM mcr.microsoft.com/dotnet/sdk:10.0.300 AS build
WORKDIR /src
COPY global.json ./
COPY src/ src/
RUN dotnet publish src/FlashSale.ProcessWorker/FlashSale.ProcessWorker.csproj \
    --configuration Release --output /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:10.0.8 AS final
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
USER root
COPY --from=build /app/publish ./
RUN mkdir -p /app/Logs && chown -R "$APP_UID":"$APP_UID" /app
USER $APP_UID
ENTRYPOINT ["dotnet", "FlashSale.ProcessWorker.dll"]
