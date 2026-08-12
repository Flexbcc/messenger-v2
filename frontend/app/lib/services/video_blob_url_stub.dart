/// Native stub — blob URLs are a web-only concept. Returns null so callers
/// fall back to the file-path path.
String? createVideoBlobUrl(List<int> bytes, String mime) => null;
void revokeVideoBlobUrl(String url) {}
