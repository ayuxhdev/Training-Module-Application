# Garden's Need Training for Android

Flutter is the Android client for Administrator, Manager and Employee workflows.
It uses the Django REST API and follows backend permissions and reporting scope.
Native Android code supports the Flutter client.

## Integration and release

Physical-device Android QA passed for the V1 integration checkpoint of
27 November 2026. Merged main CI passed Flutter analysis, Flutter tests and the
Android debug build. See the [checkpoint evidence](../docs/V1_INTEGRATION_CHECKPOINT.md).

Production signing and rollout are pending. Use company-controlled credentials
and API origin `https://training.gardensneed.com` for the signed production build.
Follow the [production runbook](../docs/V1_RELEASE_RUNBOOK.md).

See the [project README](../README.md) and [testing guide](../docs/TESTING.md).
