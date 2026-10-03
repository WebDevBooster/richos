"""The identity of RichConnect's TEST COPY, and the one rule about the CEO's own app.

The CEO's own RichConnect on his phones (iOS `dev.richos.connect`, Android `dev.richos.connect`) is his:
he installs, opens, updates and keeps it himself. Every automatic path of the phone tooling (the speed
watch, `rios device perf|install|launch|close`, `randroid device perf|install|seed`, the net check that
opens the app once) works on a SEPARATE test copy of the same release code, installed beside his app
under its own app ID, with its own data. Nothing automatic installs, launches, stops, backs up, restores
or reads `dev.richos.connect` on a phone, and every such path refuses that ID with `refuse_ceo_app`.

The same values are written, because the build tools cannot import Python, in
native-ios/project.yml + Release/platform.yml (RICHOS_BUNDLE_ID's perf override), Tools/physical-device.mjs,
native-android/app/build.gradle.kts (the `perfCopy` and `seedTwin` build types' applicationIdSuffix) and
UITests/PhysicalDeviceTests.swift; mobile-perf.test.py (TC1) checks that they all agree with this file.
"""

CEO_APP_IOS = "dev.richos.connect"
CEO_APP_ANDROID = "dev.richos.connect"
TEST_SUFFIX = ".perf"
TEST_BUNDLE_IOS = CEO_APP_IOS + TEST_SUFFIX
TEST_PACKAGE_ANDROID = CEO_APP_ANDROID + TEST_SUFFIX
# Same release code; a different name on the Home Screen / launcher so the two are told apart.
TEST_DISPLAY_NAME = "RichConnect Perf"
CEO_APP_IDS = frozenset({CEO_APP_IOS, CEO_APP_ANDROID})


class CeoAppRefused(Exception):
    """An automatic path was handed the CEO's own app."""


def refuse_ceo_app(app_id, what="this command"):
    """Raise unless `app_id` is something other than the CEO's own app."""
    if str(app_id) in CEO_APP_IDS:
        raise CeoAppRefused(f"{what} refuses {app_id}: that is the CEO's own RichConnect, which he handles himself. "
                            f"The phone tooling works only on the test copy ({TEST_BUNDLE_IOS} on an iPhone, "
                            f"{TEST_PACKAGE_ANDROID} on an Android phone).")
    return app_id
