# syntax=docker/dockerfile:1
# FlashSale.OrderService -- multi-stage image.
#
# Build context is the repository root (so the root .dockerignore applies and
# the ProjectReference to ../FlashSale.EventContracts resolves). The SDK image
# is pinned to 10.0.300 (matches global.json); the runtime is the aspnet 10.0.8
# image (the version the services are tested on locally). The app listens on plain
# HTTP inside the container (ASPNETCORE_URLS=http://+:8080) and is fronted by
# Nginx in Compose.
#
# openiddict.pfx is NOT baked in: *.pfx is excluded by the root .dockerignore,
# and the certificate is mounted read-only at runtime (infra/docker-compose.ec2.yml).
FROM mcr.microsoft.com/dotnet/sdk:10.0.300 AS build
WORKDIR /src
COPY global.json ./
COPY src/ src/
RUN dotnet publish src/FlashSale.OrderService/FlashSale.OrderService.csproj \
    --configuration Release --output /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:10.0.8 AS final
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
# The app writes Serilog's structured log to Logs/logs.json under the working
# directory, so give the non-root app user write access to /app.
USER root
COPY --from=build /app/publish ./
RUN mkdir -p /app/Logs && chown -R "$APP_UID":"$APP_UID" /app
USER $APP_UID
ENTRYPOINT ["dotnet", "FlashSale.OrderService.dll"]
