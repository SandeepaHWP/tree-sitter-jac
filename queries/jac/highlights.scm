; Comments
(comment) @comment

; Literals
(integer) @number
(float) @number.float
(string) @string
(bool) @boolean
(null) @constant.builtin
(ellipsis) @constant.builtin
(builtin_type) @type.builtin
(special_ref) @variable.builtin

; Identifiers
(identifier) @variable
(kwesc_name) @variable

; Declarations
(archetype name: (identifier) @type)
(enum name: (identifier) @type)
(ability name: (identifier) @function)
(has_var name: (identifier) @property)
(param (identifier) @variable.parameter)

; Casts, edge declarations, and import wiring
(cast_type (identifier) @type)
(import_rule name: (identifier) @type)
(module_pattern [ "any" "*" ] @constant.builtin)

; Calls & attributes
(call_expression function: (identifier) @function.call)
(attribute_expression attr: (identifier) @property)
(argument name: (identifier) @variable.parameter)

; Declaration keywords
[
  "obj" "node" "edge" "walker" "class" "enum"
  "has" "can" "def" "impl" "test" "sem" "glob"
  "static" "override" "abst" "async" "comptime" "postinit"
  "getter" "setter" "deleter"
] @keyword

; Control flow
[
  "if" "elif" "else" "while" "for" "in" "by" "forever"
  "try" "except" "finally" "awaiting" "with"
  "match" "case" "switch" "default"
  "return" "yield" "raise" "assert" "del"
  "break" "continue" "skip" "disengage"
  "visit" "report" "spawn"
] @keyword

; Import keywords
[ "import" "include" "from" "as" ] @keyword.import

; Object-spatial / context keywords
[ "entry" "exit" "lambda" "flow" "wait" "await" "graph" ] @keyword

; Ownership
[ "own" "imm" "lin" "mut" ] @keyword.modifier

; Access modifiers
[ "pub" "priv" "protect" ] @keyword.modifier

; Operators
[
  "=" ":=" "+" "-" "*" "/" "//" "%" "**" "@"
  "==" "!=" "<" ">" "<=" ">=" "&" "|" "^" "~" "<<" ">>"
  "+=" "-=" "*=" "/=" "//=" "%=" "**=" "@=" "&=" "|=" "^=" "<<=" ">>="
  "and" "or" "not" "is"
  "|>" "<|" ":>" "<:"
] @operator

; Graph / edge operators
[ "-->" "<--" "<-->" "++>" "<++" "<++>" "->:" ":->" "<-:" ":<-" "+>:" ":+>" "<+:" ":<+" ] @operator

; Decorators
(decorator_list "@" @attribute)

; f-strings (interpolations highlight as code via the rules above)
[ (fstring_start) (fstring_content) (fstring_end) ] @string
(fstring_format) @string.special
(fstring_conversion) @character.special
(fstring_interpolation [ "{" "}" ] @punctuation.special)

; JSX / view bodies
(jsx_element name: (jsx_name) @tag)
(jsx_attribute name: (jsx_name) @tag.attribute)
(jsx_text) @text

; Punctuation
[ "(" ")" "[" "]" "{" "}" ] @punctuation.bracket
[ "," ";" ":" "." "->" ] @punctuation.delimiter
