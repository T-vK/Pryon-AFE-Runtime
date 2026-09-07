# Firmware extraction

The default public firmware URL is embedded in `tools/download-firmware.sh`. The script accepts a custom URL and output directory, extracts the signed OTA/JAR, unpacks its payload images, and creates a `system_root` tree containing the Android linker, libraries, AFE configuration, dependent libraries, and models. If `payload-dumper-go` is not already available, it bootstraps the pinned upstream revision `v0.0.0-20210623033701-412e5a9dd12f` into a temporary directory and does not install anything system-wide.

The proprietary files must remain outside Git. The extracted tree is ignored by this project. The expected paths are:

```text
system_root/system/bin/linker
system_root/system/lib/libasp.so
system_root/system/lib/libpryon.so
system_root/system/vendor/etc/audio-algorithms/AFE.cfg
system_root/system/local/models/keyword/en-US/ALEXA/pryon.manifest
```

Use `tools/internal/inspect-firmware.sh ROOT` to record architecture, dependencies, and exported symbols without copying any firmware contents into the repository.
