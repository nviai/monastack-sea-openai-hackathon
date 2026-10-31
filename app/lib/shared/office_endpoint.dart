import 'dart:io';

/// Office services currently support literal loopback or private LAN IPv4 hosts.
String officeHost(String host) {
  final address = InternetAddress.tryParse(host);
  if (address == null || address.type != InternetAddressType.IPv4) {
    throw const FormatException('Office host must be an IPv4 address');
  }
  final b = address.rawAddress;
  if (!(b[0] == 127 ||
      b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168))) {
    throw const FormatException(
      'Office host must be loopback or a private LAN address',
    );
  }
  return address.address;
}

Uri? parseOfficeEndpoint(Object? value, {String scheme = 'http'}) {
  if (value is! String) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != scheme ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.path.isNotEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  try {
    officeHost(uri.host);
  } on FormatException {
    return null;
  }
  return uri;
}
