# syntax = docker/dockerfile:1


# Asegurarse de que RUBY_VERSION coincida con la versión de Ruby en .ruby-version
ARG RUBY_VERSION=3.2.2
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# La aplicación Rails reside aquí
WORKDIR /rails

# Instalar paquetes base
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 dos2unix && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Configurar el entorno de producción
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development"

# Etapa de construcción temporal para reducir el tamaño de la imagen final
FROM base AS build

# Instalar paquetes necesarios para construir gemas
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Instalar gemas de la aplicación
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Copiar el código de la aplicación
COPY . .

# Precompilar el código de bootsnap para tiempos de arranque más rápidos
RUN bundle exec bootsnap precompile app/ lib/

# Precompilación de activos para producción sin requerir la clave secreta RAILS_MASTER_KEY
RUN dos2unix bin/* && SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Etapa final para la imagen de la aplicación
FROM base

# Copiar artefactos construidos: gemas, aplicación
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Ejecutar y ser propietario solo de los archivos de tiempo de ejecución como usuario no root por seguridad
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails log tmp
# Iniciar el servidor por defecto, esto puede ser sobrescrito en tiempo de ejecución
EXPOSE 3000
CMD ["bin/rails", "server"]
