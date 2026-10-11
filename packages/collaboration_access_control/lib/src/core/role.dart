/// What a member may do. Enforced by every client when it verifies the
/// membership log, and by Row Level Security for writes to the server.
enum Role {
  owner(wireCode: 1, managesMembers: true, writesContent: true),
  editor(wireCode: 2, managesMembers: false, writesContent: true),
  viewer(wireCode: 3, managesMembers: false, writesContent: false);

  const Role({
    required this.wireCode,
    required this.managesMembers,
    required this.writesContent,
  });

  /// Stable code in signed records; never the enum index, which would
  /// silently change meaning if the roles were reordered.
  final int wireCode;
  final bool managesMembers;
  final bool writesContent;

  static Role? fromWireCode(int code) {
    for (final role in values) {
      if (role.wireCode == code) return role;
    }
    return null;
  }
}
