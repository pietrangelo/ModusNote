import 'package:meta/meta.dart';
import 'package:schema_dynamic_content/schema_dynamic_content.dart';

/// A blob in the workspace's shared storage, as a listing names it: the id
/// and when it was uploaded, nothing else.
@immutable
final class StoredBlob {
  const StoredBlob(this.id, {required this.storedAt});

  final BlobId id;
  final DateTime storedAt;
}

/// One page of a listing; [next] continues it, null on the last page.
@immutable
final class StoredBlobPage {
  const StoredBlobPage(this.blobs, {this.next});

  final List<StoredBlob> blobs;
  final String? next;
}
