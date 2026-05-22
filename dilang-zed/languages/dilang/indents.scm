; Indentation rules.
;
; Zed uses these to decide how deep to indent a new line based on the
; surrounding syntax. `@indent` increases the indent for the block; `@end`
; signals the closing line that should match the opener's indent.

[
  (block)
  (member_block)
  (impl_body)
  (struct_fields)
  (provide_body)
  (parameter_list)
  (argument_list)
  (list_literal)
  (map_literal)
  (row)
  (struct_literal)
  (match_expression)
  (enum_definition)
] @indent

[
  "}"
  ")"
  "]"
] @end
