FROM mcr.microsoft.com/vscode/devcontainers/base:ubuntu

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl unzip xz-utils zip libglu1-mesa openjdk-11-jdk build-essential \
    && rm -rf /var/lib/apt/lists/*

# Android SDK root
ENV ANDROID_SDK_ROOT=/opt/android-sdk
RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools

# Download Android command line tools
RUN curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip" -o /tmp/cmdline-tools.zip \
 && unzip /tmp/cmdline-tools.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools \
 && rm /tmp/cmdline-tools.zip \
 && mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools/latest \
 && mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools/* ${ANDROID_SDK_ROOT}/cmdline-tools/latest/ || true

ENV PATH="${PATH}:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools"

# Install Flutter (stable)
RUN git clone https://github.com/flutter/flutter.git /opt/flutter --branch stable --depth 1
ENV PATH="${PATH}:/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin"

# Install Android packages
RUN yes | ${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager --sdk_root=${ANDROID_SDK_ROOT} "platform-tools" "platforms;android-33" "build-tools;33.0.2" \
 && yes | ${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager --sdk_root=${ANDROID_SDK_ROOT} --licenses

RUN flutter --version || true
