/// Schema & Dynamic Content: meta-modello SchemaDefinition e aggregato
/// DynamicEntry.
///
/// Public API of the bounded context. Other packages import only this
/// library, never files under `src/`.
library;

export 'src/core/attachment.dart';
export 'src/core/category.dart';
export 'src/core/dynamic_entry.dart';
export 'src/core/entry_codec.dart';
export 'src/core/entry_search.dart';
export 'src/core/field_type.dart';
export 'src/core/field_value.dart';
export 'src/core/identifiers.dart';
export 'src/core/inline_images.dart';
export 'src/core/label.dart';
export 'src/core/note_links.dart';
export 'src/core/schema_catalog.dart';
export 'src/core/schema_codec.dart';
export 'src/core/schema_definition.dart';
export 'src/core/schema_exception.dart';
export 'src/core/schema_migration.dart';
export 'src/core/schema_switch.dart';
export 'src/core/seed_schemas.dart';
export 'src/core/violation.dart';
