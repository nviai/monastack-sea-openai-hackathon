/// Non-success HTTP status returned by the node.
class NodeFailure implements Exception {
  const NodeFailure(this.status);
  final int status;
}

/// Authenticated request to the configured office node.
typedef NodeRequest = Future<dynamic> Function(
  String method,
  String path, [
  Object? body,
]);
