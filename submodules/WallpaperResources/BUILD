load("//build-system/bazel-utils:swift_strict.bzl", "swift6_library")

swift6_library(
    name = "WallpaperResources",
    module_name = "WallpaperResources",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    deps = [
    	"//submodules/TelegramCore:TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/LocalMediaResources:LocalMediaResources",
        "//submodules/TinyThumbnail:TinyThumbnail",
        "//submodules/ImageBlur:ImageBlur",
        "//submodules/MediaResources:MediaResources",
        "//submodules/PhotoResources:PhotoResources",
        "//submodules/PersistentStringHash:PersistentStringHash",
        "//submodules/AppBundle:AppBundle",
        "//submodules/Svg/LegacyImpl",
        "//submodules/GZip:GZip",
        "//submodules/GradientBackground:GradientBackground",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
    ],
    visibility = [
        "//visibility:public",
    ],
)
