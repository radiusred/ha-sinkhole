# Security Policy

## Supported Versions

🔴 **Please note: until the semver for a container reaches at least 1.0.0 there is NO supported version, regardless of channel
  labels attached to them as indicated below**

All use of pre-1.0.0 versions of components is entirely at your own risk

All container images carry a semantic version tag, mapped by "channel" releases in the [manifest](https://github.com/radiusred/ha-sinkhole/releases/download/channel-manifest-artifact/manifest.yaml). You should always install either `edge` or `stable` (or another channel label if one exists) and not one of the numeric semver tags unless you've been advised to do so. This may happen for example to temporarily deal with some regression issue or incompatibility in the most recent channel version.
  
| Container Version | Supported          |
| ----------- | ------------------ |
| semver < 1.0.0     | 🔴
| `edge` (and semver >= 1.0.0)     | 🟢 |
| `stable` (and semver >= 1.0.0)      | 🟢 |
| (any other) | 🔴             |

## Reporting a Vulnerability

Please report a known or suspected vulnerability directly to one of the project maintainers and not by raising an issue in the
  project tracker. Someone will respond at the earliest opportunity and confirmed security issues are prioritised over all
  other project work.
