# os-release template
#
# Rendered to /usr/lib/os-release on the image.
# {version} is substituted at build time with IMAGE_VERSION.
# {arch} is substituted with the target platform's cpu (x86_64, aarch64, ...).
#
# Required fields for systemd discovery:
#   ID - for partition and UKI matching
#   IMAGE_ID - for sysupdate artifact matching
#   IMAGE_VERSION - for version comparison (strverscmp)
#
# See os-release(5) man page for field definitions.
{ imageId }:
{
  ID = imageId;
  NAME = "Golconda";
  VERSION_ID = "{version}";
  IMAGE_ID = imageId;
  IMAGE_VERSION = "{version}";
  PRETTY_NAME = "Golconda {version}";
  # HOME_URL, DOCUMENTATION_URL and SUPPORT_URL come from the release configuration at build time
  VARIANT = "server";
  VARIANT_ID = "server";
  # Architecture for the target platform (not the build host)
  ARCHITECTURE = "{arch}";
}
