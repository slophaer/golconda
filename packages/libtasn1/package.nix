# ASN.1 and DER, for p11-kit
{ package }:
package {
  name = "libtasn1";
  uses = [ "autotools" ];
  autotools.flags = [ "--disable-doc" ];
  bin = [ "asn1Parser" ];
}
