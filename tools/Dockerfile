# Everything needed to lint, test and run Ansible - so a Windows/macOS laptop only needs Docker + make.
FROM prom/prometheus:v3.5.0 AS prometheus
FROM prom/alertmanager:v0.28.1 AS alertmanager
FROM rhysd/actionlint:1.7.7 AS actionlint
FROM koalaman/shellcheck:v0.10.0 AS shellcheck
FROM docker:27-cli AS dockercli

FROM python:3.12-slim
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 ANSIBLE_FORCE_COLOR=1 PY_COLORS=1
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client git make curl ca-certificates rsync sshpass \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /tmp/requirements.txt
RUN pip install -r /tmp/requirements.txt
COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml -p /usr/share/ansible/collections
COPY --from=prometheus /bin/promtool /usr/local/bin/promtool
COPY --from=alertmanager /bin/amtool /usr/local/bin/amtool
COPY --from=actionlint /usr/local/bin/actionlint /usr/local/bin/actionlint
COPY --from=shellcheck /bin/shellcheck /usr/local/bin/shellcheck
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose
RUN git config --global --add safe.directory /work
WORKDIR /work
