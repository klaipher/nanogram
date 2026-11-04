load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_test")

load(
    "@build_configuration//:variables.bzl",
    "telegram_api_id",
    "telegram_api_hash",
    "telegram_app_center_id",
    "telegram_is_internal_build",
    "telegram_is_appstore_build",
    "telegram_appstore_id",
    "telegram_app_specific_url_scheme",
    "telegram_enable_icloud",
    "telegram_enable_siri",
)

objc_library(
    name = "NanogramKeyVault",
    module_name = "NanogramKeyVault",
    enable_modules = True,
    srcs = ["Sources/NanogramKeyVault.m"],
    copts = ["-Werror"],
    hdrs = ["PublicHeaders/BuildConfig/NanogramKeyVault.h"],
    includes = [
        "PublicHeaders",
    ],
    sdk_frameworks = [
        "Foundation",
        "Security",
    ],
    visibility = ["//visibility:public"],
)

swift_test(
    name = "NanogramKeyVaultTests",
    srcs = ["Tests/NanogramKeyVaultTests.swift"],
    copts = ["-warnings-as-errors"],
    deps = [":NanogramKeyVault"],
)

objc_library(
    name = "BuildConfig",
    module_name = "BuildConfig",
    enable_modules = True,
    srcs = glob(
        ["Sources/*.m"],
        exclude = ["Sources/NanogramKeyVault.m"],
    ),
    copts = [
        "-Werror",
        "-DAPP_CONFIG_API_ID={}".format(telegram_api_id),
        "-DAPP_CONFIG_API_HASH=\\\"{}\\\"".format(telegram_api_hash),
        "-DAPP_CONFIG_APP_CENTER_ID=\\\"{}\\\"".format(telegram_app_center_id),
        "-DAPP_CONFIG_IS_INTERNAL_BUILD={}".format(telegram_is_internal_build),
        "-DAPP_CONFIG_IS_APPSTORE_BUILD={}".format(telegram_is_appstore_build),
        "-DAPP_CONFIG_APPSTORE_ID={}".format(telegram_appstore_id),
        "-DAPP_SPECIFIC_URL_SCHEME=\\\"{}\\\"".format(telegram_app_specific_url_scheme),
        "-DAPP_CONFIG_IS_ICLOUD_ENABLED={}".format("true" if telegram_enable_icloud else "false"),
        "-DAPP_CONFIG_IS_SIRI_ENABLED={}".format("true" if telegram_enable_siri else "false"),
    ],
    hdrs = glob(
        ["PublicHeaders/**/*.h"],
        exclude = ["PublicHeaders/BuildConfig/NanogramKeyVault.h"],
    ),
    includes = [
        "PublicHeaders",
    ],
    deps = [
        ":NanogramKeyVault",
    ],
    visibility = ["//visibility:public"],
)
