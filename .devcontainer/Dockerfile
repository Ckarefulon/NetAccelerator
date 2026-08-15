FROM mcr.microsoft.com/devcontainers/java:1-17-bookworm

ARG ANDROID_COMMAND_LINE_TOOLS=15859902
ARG ANDROID_COMMAND_LINE_TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583

ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    PATH=/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:${PATH}

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl unzip \
    && tools_zip=/tmp/android-command-line-tools.zip \
    && curl --fail --location --retry 3 \
        "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_COMMAND_LINE_TOOLS}_latest.zip" \
        --output "${tools_zip}" \
    && echo "${ANDROID_COMMAND_LINE_TOOLS_SHA256}  ${tools_zip}" | sha256sum --check --strict \
    && mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" /tmp/android-tools \
    && unzip -q "${tools_zip}" -d /tmp/android-tools \
    && mv /tmp/android-tools/cmdline-tools "${ANDROID_SDK_ROOT}/cmdline-tools/latest" \
    && yes | sdkmanager --licenses >/dev/null \
    && sdkmanager \
        "platform-tools" \
        "platforms;android-35" \
        "build-tools;35.0.0" \
    && chmod -R a+rX "${ANDROID_SDK_ROOT}" \
    && rm -rf /tmp/android-tools "${tools_zip}" /var/lib/apt/lists/*
