FROM registry.docker.libis.be/solis/base:latest

ARG VERSION=$VERSION
ARG SERVICE=$SERVICE

WORKDIR /app
USER root

COPY app app
COPY lib lib
#COPY public public
COPY config.ru config.ru

RUN chown -R solis:solis /app

USER solis:solis

ENV RUBY_GC_HEAP_INIT_SLOTS=600000
ENV RUBY_GC_HEAP_FREE_SLOTS=200000
ENV RUBY_GC_HEAP_GROWTH_FACTOR=1.5
ENV RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR=1.0

# Metadata
LABEL org.opencontainers.image.vendor="KULeuven/LIBIS" \
	org.opencontainers.image.url="https://www.libis.be" \
	org.opencontainers.image.title="SOLIS $SERVICE image" \
	org.opencontainers.image.description="SOLIS $SERVICE image" \
	org.opencontainers.image.version="$VERSION"