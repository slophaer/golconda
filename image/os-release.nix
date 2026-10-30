# os-release template
#
# Rendered to /usr/lib/os-release on the image.
# {version} is substituted at build time with IMAGE_VERSION.
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
  HOME_URL = "https://code.in.a.flawed.cloud/yolobox/golconda";
  DOCUMENTATION_URL = "https://code.in.a.flawed.cloud/yolobox/golconda/src/branch/main/docs";
  SUPPORT_URL = "https://code.in.a.flawed.cloud/yolobox/golconda/issues";
  # No BUG_REPORT_URL - use SUPPORT_URL
  VARIANT = "server";
  VARIANT_ID = "server";
}
