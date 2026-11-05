# AWS CLI + Session Manager plugin for the real-AWS tooling (compose service aws-real):
# deploys via Run Command and the port-forwarding tunnel to the host's UIs.
# ponytail: arm64 only (the plugin rpm is per-arch); add a TARGETARCH switch for amd64 hosts.
FROM amazon/aws-cli:2.38.6@sha256:bdb0dd07c54dfc7fe6526387dcf23eaab269875a20d647ae4de8196ea04d6bd4

# AWS publishes no checksum for the plugin: this is the sha256 of the copy downloaded from
# AWS's own bucket when the version was pinned. A changed file fails the build.
ARG SMP_VERSION=1.2.896.0
ARG SMP_SHA256=edb766755393202e1193f8d2578c356a5ce409182e618b302da4e9c253d05895
RUN curl -fsSL -o /tmp/smp.rpm \
      "https://s3.amazonaws.com/session-manager-downloads/plugin/${SMP_VERSION}/linux_arm64/session-manager-plugin.rpm" \
 && echo "${SMP_SHA256}  /tmp/smp.rpm" | sha256sum -c - \
 && rpm -i /tmp/smp.rpm \
 && rm /tmp/smp.rpm
