; Outline / symbol queries.
;
; Drives Zed's outline panel (cmd-shift-o). Each `@item` is a node to surface;
; `@name` is the label shown; `@context` is text shown alongside the name.

(function_definition
  "fn" @context
  name: (identifier) @name) @item

(capability_definition
  "capability" @context
  name: (type_identifier) @name) @item

(trait_definition
  "trait" @context
  name: (type_identifier) @name) @item

(impl_block
  "impl" @context
  for_type: (_) @name) @item

(struct_definition
  "struct" @context
  name: (type_identifier) @name) @item

(enum_definition
  "enum" @context
  name: (type_identifier) @name) @item

(type_alias
  "type" @context
  name: (type_identifier) @name) @item

(scope_definition
  "scope" @context
  name: (type_identifier) @name) @item

(test_block
  "test" @context
  name: (string_literal) @name) @item

(method_signature
  "fn" @context
  name: (identifier) @name) @item

(method_with_default
  "fn" @context
  name: (identifier) @name) @item
