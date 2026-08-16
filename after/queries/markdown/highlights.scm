;extends

;; Code blocks aren't prose -- upstream already excludes inline `code spans`
;; (markdown_inline/highlights.scm) but not these block-level forms.
(fenced_code_block) @nospell
(indented_code_block) @nospell
