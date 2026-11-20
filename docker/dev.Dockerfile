# The environment Pitstop is developed and measured in: Ruby plus the libraries the apps we test on
# need to install their gems (SQLite, MySQL and PostgreSQL clients, libvips for images).
ARG RUBY_VERSION=3.4
FROM ruby:${RUBY_VERSION}-slim

RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
      build-essential git curl pkg-config \
      libpq-dev default-libmysqlclient-dev libssl-dev \
      libsqlite3-dev sqlite3 \
      libyaml-dev zlib1g-dev libvips-dev \
      libidn-dev libicu-dev \
 && rm -rf /var/lib/apt/lists/*

ENV BUNDLE_JOBS=8 \
    BUNDLE_RETRY=3 \
    LANG=C.UTF-8

WORKDIR /pitstop
