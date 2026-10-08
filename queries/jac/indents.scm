; Indentation (nvim-treesitter indent engine).
; Indent the contents of every brace/bracket/paren-delimited construct, and
; dedent on the matching closing token.

[
  (block_body)
  (argument_list)
  (parameter_list)
  (list)
  (set)
  (dict)
  (import_items)
  (list_comprehension)
  (set_comprehension)
  (dict_comprehension)
  (parenthesized_expression)
  (type_params)
  (impl_import)
  (wire_payload)
  (graph_expression)
] @indent.begin

[
  "}"
  "]"
  ")"
] @indent.end

; Keep closing brackets and case/else branches aligned with their opener.
(comment) @indent.ignore
